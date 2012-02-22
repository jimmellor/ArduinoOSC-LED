#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'socket' # Strange side effects with eventmachine udp client and SuperCollider
require 'strscan'
require 'thread'


# IPs and ports of arduino (client) and reaktor (Server)
reaktorIP = 'localhost'
reaktorPort = 10001

arduinoIP = '192.168.1.10'
arduinoPort = 10000



module OSC
  Thread  = EM.reactor_running? ? nil : Thread.new { 
    EM.run do 
      EM.error_handler { |e| puts e }
      EM.set_quantum 5 
    end	
  }
  Thread.run if RUBY_VERSION.to_f >= 1.9
    
  class DecodeError < StandardError; end
  
  class Blob < String; end
  
  module OSCArgument
    def to_osc_type
      raise NotImplementedError, "#to_osc_type method should be implemented for #{ self.class }"
    end
  end
  
  def self.coerce_argument arg
    case arg
    when OSCArgument then arg.to_osc_type
    when Symbol      then arg.to_s
    when String, Float, Fixnum, Blob, String then arg # Pure osc 1.0 specification
    else raise(TypeError, "#{ arg.inspect } is not a valid Message argument") end
  end
  
  def self.decode str #:nodoc:
    str.match(/^#bundle/) ? Bundle.decode(str) : Message.decode(str)
  end
  
  def self.padding_size size
    (4 - (size) % 4) % 4 
  end
  
  def self.encoding_directive obj #:nodoc:
    case obj
    when Float  then [obj, 'f', 'g']
    when Fixnum then [obj, 'i', 'N']
    when Blob   then [[obj.size, obj], 'b', "Na*x#{ padding_size obj.size + 4 }"]
    when String then [obj, 's', "Z*x#{ padding_size obj.size + 1 }"]
    when Time
      t1, fr = (obj.to_f + 2208988800).divmod(1)
      t2 = (fr * (2**32)).to_i
      [[t1, t2], 't', 'N2']
    end
  end

  
  VERSION = "0.3.4"
  
  class Bundle < Array
    attr_accessor :timetag

    def initialize timetag = nil, *args
      args.each{ |arg| raise TypeError, "#{ arg.inspect } is required to be a Bundle or Message" unless Bundle === arg or Message === arg }
      raise TypeError, "#{ timetag.inspect } is required to be Time or nil" unless timetag == nil or Time === timetag
      super args
      @timetag = timetag
    end

    def encode
      timetag =
      if @timetag
        time, tag, dir = OSC.encoding_directive @timetag
        time.pack dir
      else "\000\000\000\000\000\000\000\001" end
        
      "#bundle\000#{ timetag }" + collect do |x|
        x = x.encode
        [x.size].pack('N') + x
      end.join
    end

    def self.decode string
      string.sub! /^#bundle\000/, ''
      t1, t2, content_str = string.unpack('N2a*')
      
      timetag   = t1 == 0 && t2 == 1 ? nil : Time.at(t1 + t2 / (2**32.0) - 2_208_988_800)
      scanner   = StringScanner.new content_str
      args      = []
      
      until scanner.eos?
        size    = scanner.scan(/.{4}/).unpack('N').first
        arg_str = scanner.scan(/.{#{ size }}/nm) rescue raise(DecodeError, "An error occured while trying to decode bad formatted osc bundle")
        args   << OSC.decode(arg_str)
      end
      
      new timetag, *args
    end
    
    def == other
      self.class == other.class and self.timetag == other.timetag and self.to_a == other.to_a
    end

    def to_a; Array.new self; end
    
    def to_s
      "OSC::Bundle(#{ self.join(', ') })"
    end
  end
  
  class Client
 
    def initialize port, host
      @socket = UDPSocket.new
      @socket.connect host, port
    end
 
    def send mesg, *args
      @socket.send mesg.encode, 0
    end
  end
  
  class Message
    attr_accessor :address, :time, :args

    def initialize address = '', *args
      args.collect! { |arg| OSC.coerce_argument arg }
      args.flatten! # won't harm we're not accepting arrays anyway, in case an custom coerced arg coerces to Array eg. Hash
      raise(TypeError, "Expected address to be a string") unless String === address
      @address, @args = address, args
    end

    def encode
      objs, tags, dirs = @args.collect { |arg| OSC.encoding_directive arg }.transpose
      dirs ||= [] and objs ||= []

      [",#{ tags and tags.join }", @address].each do |str|
        obj, tag, dir = OSC.encoding_directive str
        objs.unshift obj
        dirs.unshift dir
      end

      objs.flatten.compact.pack dirs.join
    end

    def == other
      self.class == other.class and to_a == other.to_a
    end

    def to_a; @args.dup.unshift(@address) end
    def to_s; "OSC::Message(#{ args.join(', ') })" end

    def self.decode string
      scanner        = StringScanner.new string
      address, tags  = (1..2).map do
        string       = scanner.scan(/[^\000]+\000/)
        scanner.pos += OSC.padding_size(string.size)
        string.chomp("\000")
      end

      args = []
      tags.scan(/\w/) do |tag|
        case tag
        when 'i'
          int = scanner.scan(/.{4}/nm).unpack('N').first
          args.push( int > (2**31-1) ? int - 2**32 : int )
        when 'f'
          args.push scanner.scan(/.{4}/nm).unpack('g').first
        when 's'
          str = scanner.scan(/[^\000]+\000/)
          scanner.pos += OSC.padding_size(str.size)
          args.push str.chomp("\000")
        when 'b'
          size = scanner.scan(/.{4}/).unpack('N').first
          str  = scanner.scan(/.{#{ size }}/nm)
          scanner.pos += OSC.padding_size(size + 4)
          args.push Blob.new(str)
        else
          raise DecodeError, "#{ t } is not a known tag"
        end
      end

      new address, *args
    end

  end
  
  class Server
    attr_accessor :port, :address

    def initialize port, address
      @port, @address   = port, address
      @queue, @patterns = [], []
      @mutex = Mutex.new
      run
    end

    def run
      @connection = EventMachine.open_datagram_socket @address, @port, Connection, self
      check_queue
    end

    def stop
      return unless @connection
      @connection.close_connection
      @timer.cancel
    end

    def add_pattern pattern, &block
      raise ArgumentError.new("A block must be given") unless block
      @patterns << [pattern, block]
    end

    def delete_pattern pattern
      @patterns.delete pattern
    end

    def receive data
      case decoded = OSC.decode(data)
      when Bundle
        decoded.timetag.nil? ? decoded.each{ |m| dispatch m } : @mutex.synchronize{@queue.push(decoded)}
      when Message
        dispatch decoded
      end
      rescue => e 
        warn "Bad data received: #{ e }"
    end

    private
    def check_queue
      @timer = EventMachine::PeriodicTimer.new 0.002 do
        now  = Time.now
        @mutex.synchronize do
          @queue.delete_if do |bundle|
            bundle.each{ |m| dispatch m } if delete = now >= bundle.timetag
            delete
          end
        end
      end
    end

    def dispatch message
      @patterns.each do |pat, block| 
        block.call(*message.to_a) if pat === message.address
      end
    end

    class Connection < EventMachine::Connection #:nodoc:
      def initialize server
        @server = server
      end

      def receive_data data
        @server.receive(data) 
      end
    end
  end
  
  
end

####################################
# LET'S DO THIS THING:

# require 'rubygems'
# require "#{ File.dirname __FILE__ }/../lib/ruby-osc" x
# require 'ruby-osc'

include  OSC
puts "********************************"
puts "*    OSC UNBUNDLER MASCHINE    *"
puts "* ~~~~~~~~~~~~~~~~~~~~~~~~~~~~ *"
puts "********************************"
server = Server.new(reaktorPort, reaktorIP )
client = Client.new(arduinoPort, arduinoIP )

puts "Listening on  #{reaktorIP}:#{reaktorPort}"
puts "Sending to    #{arduinoIP}:#{arduinoPort}"  

server.add_pattern /ardosc*/ do |*args|       # this will match any address beginning ardosc
  now = Time.now
  puts"\r#{now.strftime("%Y-%m-%d %H:%M:%S")}:#{now.usec/1000.to_i}\t#{args.join(' ')}"
  client.send Message.new( args[0], args[1] )
end

OSC::Thread.join