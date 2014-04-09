ZooKeeperWatcher = require 'zookeeper-watcher'
{EventEmitter} = require 'events'
zkProto = require './zk-protobuf'
Connection = require './connection'
Get = require './get'
Put = require './put'
Delete = require './delete'
Scan = require './scan'
debugzk = (require 'debug') 'zk'
debug = (require 'debug') 'hbase-client'
crypto = require 'crypto'
async = require 'async'

ProtoBuf = require("protobufjs")
ProtoBuf.convertFieldsToCamelCase = true
builder = ProtoBuf.loadProtoFile("#{__dirname}/../proto/Client.proto")
proto = builder.build()

md5sum = (data) ->
	crypto.createHash('md5').update(data).digest('hex')

SERVERNAME_SEPARATOR = ","
META_TABLE_NAME = new Buffer 'hbase:meta'
META_REGION_NAME = new Buffer 'hbase:meta,,1'
MAGIC = 255
MD5_HEX_LENGTH = 32

module.exports = class Client extends EventEmitter
	constructor: (options) ->
		super()

		options.zookeeperRoot = options.zookeeperRoot or "/hbase"
		options.zookeeperHosts = options.zookeeper.quorum.split(SERVERNAME_SEPARATOR) if options.zookeeper and typeof options.zookeeper.quorum is "string"

		@zk = new ZooKeeperWatcher
			hosts: options.zookeeperHosts
			root: options.zookeeperRoot

		@servers = {}
		@serversLength = 0
		@cachedRegionLocations = {}
		@rpcTimeout = 30000
		@pingTimeout = 30000
		@zkStart = "init"
		@rootRegionZKPath = options.rootRegionZKPath or '/meta-region-server'
		@ensureZookeeperTrackers (err) =>
			@emit 'error', err if err


	ensureZookeeperTrackers: (cb) =>
		return cb() if @zkStart is "done"
		@once "ready", cb
		return if @zkStart is "starting"
		@zkStart = "starting"

		@zk.once "connected", (err) =>
			if err
				@zkStart = "error"
				debugzk "[%s] [worker:%s] [hbase-client] zookeeper connect error: %s", new Date(), process.pid, err.stack
				return @emit "ready", err
			@zk.unWatch @rootRegionZKPath
			@zk.watch @rootRegionZKPath, (err, value, zstat) =>
				firstStart = @zkStart isnt "done"
				if err
					debugzk "[%s] [worker:%s] [hbase-client] zookeeper watch error: %s", new Date(), process.pid, err.stack
					if firstStart
						# only first start fail will emit ready event
						@zkStart = "error"
						@emit "ready", err
					return

				rootServer = zkProto.decodeMeta value
				@zkStart = "done"
				oldServer = @rootServer or server: hostName: 'none', port: 'none'
				@rootServer = rootServer.server

				serverName = @getServerName @rootServer
				@getRegionConnection serverName, (err, server) =>
					return cb err if err
					debugzk "zookeeper start done, got new root #{serverName}, old #{oldServer?.server?.hostName}:#{oldServer?.server?.port}"

					# only first start success will emit ready event
					@emit "ready" if firstStart

				#@locateRegion META_TABLE_NAME


	getServerName: (hostname, port) ->
		if typeof hostname is 'object'
			port = hostname.port
			hostname = hostname.hostName

		"#{hostname}:#{port}"


	locateNextRegion: (region, cb) =>


	locateRegion: (table, row, useCache, cb) =>
		if typeof useCache is 'function'
			cb = useCache
			useCache = yes

		debug "locateRegion table: #{table} row: #{row}"
		table = new Buffer table unless Buffer.isBuffer table
		row = new Buffer(row or [0])

		@ensureZookeeperTrackers (err) =>
			return cb err if err

			@locateRegionInMeta table, row, useCache, cb


	locateRegionInMeta: (table, row, useCache, cb) =>
		debug "locateRegionInMeta table: #{table} row: #{row}"
		region = @createRegionName(table, row, '', yes)
		req =
			region:
				type: "REGION_NAME"
				value: META_REGION_NAME
			gxt:
				row: region
				column:
					family: "info"
				closestRowBefore: yes

		if useCache
			cachedRegion = @getCachedLocation table, row
			return cb null, cachedRegion if cachedRegion

		@getRegionConnection @rootServer.hostName, @rootServer.port, (err, server) =>
			server.rpc.Get req, (err, response) =>
				if err
					debug "locateRegionInMeta error: #{err}"
					return cb err

				region = {}
				if response?.result
					for res in response.result.cell
						qualifier = res.qualifier.toBuffer().toString()

						if qualifier is 'server'
							region.server = res.value.toBuffer()

						if qualifier is 'regioninfo'
							b = res.value.toBuffer()
							regionInfo = b.slice b.toString().indexOf('PBUF') + 4
							regionInfo = proto.RegionInfo.decode regionInfo
							region.startKey = regionInfo.startKey.toBuffer()
							region.endKey = regionInfo.endKey.toBuffer()
							region.name = res.row.toBuffer()
							region.ts = res.timestamp

				unless region.server
					err = "region for table #{table} not found"
					cb err
					return debug err

				@cacheLocation table, region
				cb null, region


	cacheLocation: (table, region) =>
		@cachedRegionLocations[table] ?= {}
		@cachedRegionLocations[table][region.name] = region


	bufferCompare: (a, b) ->
		len1 = a.length
		len2 = b.length

		return 0 if a is b and len1 is len2

		for i, v of a
			if a[i] isnt b[i]
				return a[i] - b[i]

		len1 - len2


	getCachedLocation: (table, row) =>
		return null unless @cachedRegionLocations[table] and Object.keys(@cachedRegionLocations[table]).length > 0
		cachedRegions = Object.keys(@cachedRegionLocations[table])

		for cachedRegion in cachedRegions
			startKey = @cachedRegionLocations[table][cachedRegion].startKey
			endKey = @cachedRegionLocations[table][cachedRegion].endKey

			if @bufferCompare(row, endKey) <= 0 and @bufferCompare(row, startKey) > 0
				debug "Found cached regionLocation #{cachedRegion}"
				return @cachedRegionLocations[table][cachedRegion]

		null


	printRegion: (region) ->
		o =
			startKey: region.startKey.toString()
			endKey: region.endKey.toString()
			name: region.name.toString()
			ts: region.ts.toString()
			server: region.server.toString()


	parseResponse: (res) =>
		# TODO: upravit strukturu
		o =
			row: res.row.toBuffer().toString()
			family: res.family.toBuffer().toString()
			qualifier: res.qualifier.toBuffer().toString()
			value: res.value.toBuffer().toString()
			timestamp: res.timestamp.toString()


	createRegionName: (table, startKey, id, newFormat) =>
		table = new Buffer table unless Buffer.isBuffer table
		startKey = new Buffer(startKey or [0])
		id = new Buffer(id?.toString() or [0])
		delim = new Buffer ','
		b = Buffer.concat [table, delim, startKey, delim, id]
		md5 = new Buffer(md5sum b)

		delim = new Buffer '.'
		return Buffer.concat [b, delim, md5, delim] if newFormat

		b


	_action: (method, table, obj, useCache, retry, cb) =>
		if typeof useCache is 'function'
			cb = useCache
			useCache = yes
			retry = 0
		else if typeof retry is 'function'
			cb = retry
			retry = 0

		@locateRegion table, obj.row, useCache, (err, location) =>
			return cb err if err

			@getRegionConnection location.server.toString(), (err, server) =>
				return cb err if err

				if method is 'get'
					req =
						region:
							type: "REGION_NAME"
							value: location.name
						gxt: obj.getFields()

					result = []
					server.rpc.Get req, (err, response) =>
						return cb err if err

						for res in response.result.cell
							result.push @parseResponse res

						cb null, result
				else if method in ['put', 'delete']
					req =
						region:
							type: "REGION_NAME"
							value: location.name
						mutation: obj.getFields()

					result = []
					server.rpc.Mutate req, cb


	_multiAction: (table, multiActions, useCache, retry, cb) =>
		if typeof useCache is 'function'
			cb = useCache
			useCache = yes
			retry = 0
		else if typeof retry is 'function'
			cb = retry
			retry = 0

		req =
			regionAction: []

		result = []
		async.each Object.keys(multiActions), (serverName, done) =>
			for region, actions of multiActions[serverName]
				operations = []

				for action in actions
					if action.method is 'get'
						operations.push gxt: action.getFields()
					else if action.method in ['put', 'delete']
						operations.push mutation: action.getFields()

				req.regionAction.push
					region:
						type: "REGION_NAME"
						value: region
					action: operations

			@getRegionConnection serverName, (err, server) =>
				return done err if err

				server.rpc.Multi req, (err, res) =>
					return done err if err

					for serverResult in res.regionActionResult
						for response in serverResult.resultOrException
							for cell in response.result.cell
								result.push @parseResponse cell

					done()
		, (err) =>
			cb err, result


	getScanner: (table, startRow, stopRow, filter) =>
		new Scan table, startRow, stopRow, filter, @


	get: (table, get, cb) =>
		debug "get on table: #{table} get: #{get}"
		@_action 'get', table, get, cb


	put: (table, put, cb) =>
		debug "put on table: #{table} put: #{put}"
		@_action 'put', table, put, cb


	delete: (table, del, cb) =>
		debug "delete on table: #{table} delete: #{del}"
		@_action 'delete', table, del, cb


	mget: (table, rows, columns, opts, cb) =>
		return cb "Input is expected to be an array" unless Array.isArray(rows) and rows.length > 0
		debug "mget on table: #{table} #{rows.length} rows"

		if typeof columns is 'function'
			cb = columns
			opts = {}
			columns = []
		else if typeof opts is 'function'
			cb = opts
			opts = {}

		workingList = []
		for row in rows
			if row instanceof Get
				get = row
			else
				get = new Get row

				if columns
					for column in columns
						column = column.split ':'
						get.addColumn column[0], column[1]

			get.method = 'get'
			workingList.push get

		@processBatch table, workingList, true, 0, (err, results) =>
			cb err, results


	mput: (table, rows, opts, cb) =>
		return cb "Input is expected to be an array" unless Array.isArray(rows) and rows.length > 0
		debug "mput on table: #{table} #{rows.length} rows"

		if typeof columns is 'function'
			cb = columns
			opts = {}
			columns = []
		else if typeof opts is 'function'
			cb = opts
			opts = {}

		workingList = []
		for row in rows
			if row instanceof Put
				put = row
			else
				put = new Put row.row

				for column, value of row
					continue if column is 'row'

					column = column.split ':'
					put.add column[0], column[1], value

			put.method = 'put'
			workingList.push put

		@processBatch table, workingList, true, 0, (err, results) =>
			cb err, results


	mdelete: (table, rows, opts, cb) =>
		return cb "Input is expected to be an array" unless Array.isArray(rows) and rows.length > 0
		debug "mdelete on table: #{table} #{rows.length} rows"

		if typeof columns is 'function'
			cb = columns
			opts = {}
			columns = []
		else if typeof opts is 'function'
			cb = opts
			opts = {}

		workingList = []
		for row in rows
			if row instanceof Delete
				del = row
			else
				del = new Delete row

			del.method = 'delete'
			workingList.push del

		@processBatch table, workingList, true, 0, (err, results) =>
			cb err, results


	processBatch: (table, workingList, useCache, retry, cb) =>
		if typeof useCache is 'function'
			cb = useCache
			useCache = yes

		actionsByServer = {}

		workingList.filter (item) ->
			item?

		return cb null, [] if workingList.length is 0

		async.each workingList, (row, done) =>
			@locateRegion table, row.getRow(), useCache, (err, location) =>
				return done err if err

				actionsByServer[location.server] ?= {}
				actionsByServer[location.server][location.name] ?= []
				actionsByServer[location.server][location.name].push row
				done()
		, (err) =>
			return cb err if err
			@_multiAction table, actionsByServer, useCache, retry, cb


	# TODO
	prefetchRegionCache: (table, row, cb) =>
		startRow = ''


	getRegionConnection: (serverName, port, cb) =>
		if typeof port is 'function'
			cb = port
			[hostname, port] = serverName.split ':'
		else
			serverName = @getServerName serverName, port

		server = @servers[serverName]
		if server
			if server.state is "ready"
				debug "getRegionConnection from cache (servers: #{@serversLength}), #{serverName}"
				cb null, server
			else
				server.on 'ready', () ->
					cb null, server
			return

		debug "getRegionConnection connecting to #{serverName}"
		server = new Connection(
			host: hostname
			port: port
			rpcTimeout: @rpcTimeout
			logger: @logger
		)
		server.state = "connecting"

		# cache server
		@servers[serverName] = server
		@serversLength++
		timer = null
		handleConnectionError = handleConnectionError = (err) =>
			if timer
				clearTimeout timer
				timer = null
			delete @servers[serverName]

			@serversLength--

			# avoid 'close' and 'connect' event emit.
			server.removeAllListeners()
			server.close()
			debug err.message


		# handle connect timeout
		timer = setTimeout () =>
			err = "#{serverName} connect timeout, " + @rpcTimeout + " ms"
			handleConnectionError err
			return
		, @rpcTimeout

		server.once "connect", =>
			debug "%s connected, total %d connections", serverName, @serversLength
			server.state = "ready"
			server.emit 'ready'
			clearTimeout timer
			timer = null
			cb null, server


		server.once "connectError", handleConnectionError

		# TODO: connection always emit close event?
		#server.once "close", @_handleConnectionClose.bind(@, serverName)









