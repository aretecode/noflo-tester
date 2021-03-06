noflo = require 'noflo'
Promise = require 'bluebird'
trace = require('noflo-runtime-base').trace

# Tester loads and wraps a NoFlo component or graph
# for testing it with input and output commands.
class Tester
  # Constructor accepts the following arguments:
  #
  # - `component`: full name of the component (including library prefix),
  #   or an already loaded component instance, or a custom function that
  #   returns a new instance.
  # - `options`: a map of custom options, including:
  #   - `load`: a callback `function(err, instance)` called after loading
  #     a new object instance;
  #   - `ready`: a callback `function(err, instance)` called when instance
  #     is ready.
  constructor: (@component, @options = {}) ->
    if typeof(@component) is 'object'
      @c = @component
    else if typeof(@component) is 'function'
      @c = @component()
    else
      if process.env.NOFLO_TEST_BASEDIR
        @baseDir = process.env.NOFLO_TEST_BASEDIR
      else
        @baseDir = process.cwd()
      @loader = new noflo.ComponentLoader @baseDir, cache: true
    if @options.debug
      # instantiate our Tracer
      @tracer = new trace.Tracer()

  # Loads a component, attaches inputs and outputs and starts it.
  #
  #  - `done`: a callback `function(err, instance)` called after starting
  #   a component instance.
  start: (done) ->
    whenReady = =>
      @options.ready null, @c if typeof(@options.ready) is 'function'
      @ins = {}
      @outs = {}
      Object.keys(@c.inPorts).forEach (name) =>
        return if typeof(@c.inPorts[name].attach) isnt 'function'
        socket = noflo.internalSocket.createSocket()
        @c.inPorts[name].attach socket
        @ins[name] = socket
      Object.keys(@c.outPorts).forEach (name) =>
        return if typeof(@c.outPorts[name].attach) isnt 'function'
        socket = noflo.internalSocket.createSocket()
        @c.outPorts[name].attach socket
        @outs[name] = socket
      @c.start()
      done null, @c if typeof(done) is 'function'
    if @c
      whenReady()
    else
      @loader.load @component, (err, instance) =>
        @options.load err, instance if typeof(@options.load) is 'function'
        return done err if err and done
        return if err
        @c = instance
        if typeof(@c.loader) is 'object'
          # Graphs need to wait for ready event
          @c.once 'ready', ->
            if @options.debug
              @tracer.attach @network

            whenReady()
        else
          whenReady()

  dumpTrace: (fileName = null) =>
    if @options.debug
      @tracer.dumpFile fileName, (err, f) ->
        throw err if err
        console.log 'Wrote flowtrace to', f

  # Sends data packets to one or multiple inports and disconnects them.
  #
  # It accepts either a single hashmap argument mapping port names to data,
  # or a pair of arguments with port name and data to sent to that single
  # port.
  send: (hashmap, singleData) =>
    if typeof(hashmap) is 'string'
      port = hashmap
      hashmap = {}
      hashmap[port] = singleData
    for port, value of hashmap
      throw new Error "No such inport: #{port}" unless port of @ins
      @ins[port].send value
      @ins[port].disconnect()

  # Listens for a transmission from an outport of a component until next
  # disconnect event.
  #
  # The `callback` parameter is passed the following arguments:
  # `(data, groups, dataCount, groupCount)`. If there were multiple data
  # packets, `data` is an array of length passed in `dataCount`. `groupCount`
  # contains the number of complete (closed) groups.
  #
  # Returns a promise that is resolved when a value is received.
  #
  # You can pass a hashmap of `port: callback` to this method. The returned
  # promise is resolved after data from all ports in the map have been
  # received.
  receive: (port, callback) =>
    getTask = (portName, done) =>
      throw new Error "No such outport: #{portName}" unless portName of @outs
      return (resolve, reject) =>
        data = []
        dataCount = 0
        groups = []
        groupCount = 0
        @outs[portName].removeAllListeners()
        @outs[portName].on 'data', (packet) ->
          data.push packet
          dataCount++
        @outs[portName].on 'begingroup', (group) ->
          # Capture only unique groups
          unless groups.indexOf(group) isnt -1
            groups.push group
            groupCount++
        @outs[portName].on 'disconnect', =>
          @outs[portName].removeAllListeners()
          data = data[0] if dataCount is 1
          done data, groups, dataCount, groupCount if done
          resolve data
    if typeof(port) is 'object'
      # Map of port: callback
      tasks = []
      for name, callback of port
        tasks.push new Promise getTask name, callback
      return Promise.all tasks
    else
      return new Promise getTask port, callback

module.exports = Tester
