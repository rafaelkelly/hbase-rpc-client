ProtoBuf = require("protobufjs")
ByteBuffer = require 'protobufjs/node_modules/bytebuffer'

ProtoBuf.convertFieldsToCamelCase = true
builder = ProtoBuf.loadProtoFile("#{__dirname}/../proto/Client.proto")
proto = builder.build()

#console.log proto.MutationProto

module.exports = class Put
	constructor: (@row, @ts) ->
		@familyMap = {}


	add: (cf, qualifier, value, timestamp) =>
		timestamp ?= ByteBuffer.Long.MAX_VALUE

		@familyMap[cf] ?= []
		@familyMap[cf].push {qualifier, value, timestamp}


	getFields: () =>
		o =
			row: @row
			mutateType: "PUT"
			columnValue: []

		for cf, qualifierValue of @familyMap
			o.columnValue.push
				family: cf
				qualifierValue: qualifierValue

		o


	getRow: () =>
		@row




