// Generated by CoffeeScript 1.12.7
(function() {
  var ByteBuffer, DataOutputBuffer, DataOutputStream,
    bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; },
    slice = [].slice,
    extend = function(child, parent) { for (var key in parent) { if (hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
    hasProp = {}.hasOwnProperty;

  ByteBuffer = require('bytebuffer');

  DataOutputStream = (function() {
    function DataOutputStream(out) {
      this.out = out;
      this.writeDelimitedBuffers = bind(this.writeDelimitedBuffers, this);
      this.writeInt = bind(this.writeInt, this);
      this.writeByte = bind(this.writeByte, this);
      this.write = bind(this.write, this);
      this.written = 0;
    }

    DataOutputStream.prototype.write = function(b, offset, length) {
      if (!Buffer.isBuffer(b)) {
        b = new Buffer(b);
      }
      if (length == null) {
        length = b.length;
      }
      if (offset) {
        b = b.slice(offset, offset + length);
      }
      this.out.write(b);
      return this.written += length;
    };

    DataOutputStream.prototype.writeByte = function(b) {
      if (!Buffer.isBuffer(b)) {
        if (isNaN(b)) {
          b = new Buffer(b[0]);
        } else {
          b = new Buffer([b]);
        }
      }
      return this.write(b);
    };

    DataOutputStream.prototype.writeInt = function(i) {
      var b;
      b = new Buffer(4);
      b.writeInt32BE(i, 0);
      return this.write(b);
    };

    DataOutputStream.prototype.writeDelimitedBuffers = function() {
      var bb, buffer, buffers, i, length, results, varInt;
      buffers = 1 <= arguments.length ? slice.call(arguments, 0) : [];
      length = 0;
      varInt = [];
      for (i in buffers) {
        buffer = buffers[i];
        varInt[i] = ByteBuffer.calculateVarint32(buffer.length);
        length += varInt[i] + buffer.length;
      }
      this.writeInt(length);
      results = [];
      for (i in buffers) {
        buffer = buffers[i];
        bb = new ByteBuffer(varInt[i]);
        bb.writeVarint32(buffer.length);
        this.write(bb.toBuffer());
        results.push(this.write(buffer));
      }
      return results;
    };

    return DataOutputStream;

  })();

  DataOutputBuffer = (function(superClass) {
    extend(DataOutputBuffer, superClass);

    function DataOutputBuffer() {
      DataOutputBuffer.__super__.constructor.call(this);
    }

    return DataOutputBuffer;

  })(DataOutputStream);

  module.exports.DataOutputBuffer = DataOutputBuffer;

  module.exports.DataOutputStream = DataOutputStream;

}).call(this);
