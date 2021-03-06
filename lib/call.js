// Generated by CoffeeScript 1.12.7
(function() {
  var Call, debug,
    bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; };

  debug = (require('debug'))('hbase-call');

  module.exports = Call = (function() {
    function Call(responseClass, header, timeout, cb) {
      this.responseClass = responseClass;
      this.header = header;
      this.timeout = timeout;
      this.cb = cb;
      this.complete = bind(this.complete, this);
      this.called = false;
      this.startTime = new Date;
      this.timer = setTimeout((function(_this) {
        return function() {
          debug("operation " + _this.header.callId + " (" + _this.header.methodName + ") timedout after " + _this.timeout + "ms");
          _this.called = true;
          return _this.cb('timedout');
        };
      })(this), this.timeout);
      debug("operation " + this.header.callId + " (" + this.header.methodName + ") called");
    }

    Call.prototype.complete = function(err, data) {
      if (this.called) {
        return;
      }
      debug("operation " + this.header.callId + " (" + this.header.methodName + ") completed. Took: " + (new Date - this.startTime) + "ms");
      clearTimeout(this.timer);
      return this.cb(err, data);
    };

    return Call;

  })();

}).call(this);
