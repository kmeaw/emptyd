# vim: ai:ts=2:sw=2:et:syntax=ruby
require "emptyd/version"

require 'fiber'
require 'em-ssh'
require 'securerandom'
require 'json'

module Emptyd
  $0 = "emptyd"
  LOG = Logger.new(STDERR)

  class Connection
    attr_reader :key, :updated_at, :failed_at, :error
    EXPIRE_INTERVAL = 600 # 10min
    MAX_CONNECTIONS = 30
    HAPPY_RATIO = 0.5
    @@connections = {}
    @@count = {}

    def self.[](key)
      @@connections[key] or Connection.new(key)
    end

    def initialize(key)
      raise IOError, "already registered" if @@connections[key]
      @key = key
      @sessions = []
      @user, @host = key.split('@', 2)
      @user, @host = "root", @user if @host.nil?
      @@connections[key] = self
      @run_queue = []
      self.start
      @timer = EM::PeriodicTimer.new(rand(5..15)) do
        start
        destroy if old? and free?
      end
    end

    def destroy
      raise IOError, "sessions are still alive" unless @sessions.empty?
      @timer.cancel
      @start_timer.cancel if @start_timer
      @@connections.delete @key
      if @conn
        @@count.delete self.key
        conn = @conn
        @conn = nil
        Fiber.new do
          conn.close
        end.resume
      end
      LOG.debug "Destroying connection #{@key}"
    end

    def start
      return if @conn or @connecting
      @connecting = true

      pressure = proc do
        if @@count.size >= MAX_CONNECTIONS # pressure
          c = @@count.select{|k,c| c.free?}.values.sample
          if c
            c.destroy
          else
            LOG.debug "pressure: no free connections: #{@@count.keys}"
          end
        end
      end

      starter = proc do
        begin
          pressure[]
          if @@count.size >= MAX_CONNECTIONS
            LOG.debug "Quota exceeded by #{@key}: #{@@count.size}"
            @start_timer = EM::PeriodicTimer.new(rand(1..10)) do
              pressure[]
              if @@count.size < MAX_CONNECTIONS
                @start_timer.cancel
                EM.next_tick starter
              else
                LOG.debug "No more connection quota, deferring #{@key}..."
              end
            end
          else
            @@count[self.key] = self
            LOG.debug "Created new conn: #{key}, quota = #{@@count.size}"
            EM::Ssh.start(@host, @user, user_known_hosts_file: []) do |conn|
              conn.errback { |err| errback err }
              conn.on(:closed) { errback "closed" }
              conn.callback do |ssh|
                @conn = ssh
                @error = nil
                @failed_at = nil
                @updated_at = Time.now
                @connecting = false
                @run_queue.each do |cmd,session,callback|
                  if session.dead?
                    LOG.debug "Dropping pending run request from a dead session"
                    @error = "session is dead"
                  else
                    EM.next_tick { run cmd, session, &callback }
                  end
                end
                @run_queue.clear
                if @error
                  ssh.close
                  @@count.delete self.key
                end
              end
            end
          end
        rescue EventMachine::ConnectionError => e
          @@count.delete self.key
          @conn = nil
          @error = e
          @failed_at = Time.now
          @connecting = false
          @run_queue.each do |cmd,session,callback|
            callback.call self, :error
          end
        end
      end

      EM.next_tick starter
    end

    def errback err
      @@count.delete self.key
      had_valid_conn = !!@conn
      @conn = nil
      STDERR.puts "Connection to #{@key} is broken: #{err}"
      @error = err
      @failed_at = Time.now
      @connecting = false
      if had_valid_conn
        @sessions.each do |session|
          session.queue.push [self, :error, nil]
        end
      else
        @run_queue.each do |cmd,session,callback|
          callback.call self, :error
        end
      end
    end

    def bind(session)
      raise IOError, "already bound" if @sessions.include? session
      @sessions << session
    end

    def unbind(session)
      raise IOError, "not bound" unless @sessions.include? session
      @run_queue.delete_if{|cmd,sess,cb| sess == session}
      @sessions.delete session
    end

    def run cmd, session, &callback
      unless @conn
        @run_queue << [cmd, session, callback]
        return
      end

      setup = proc do |ch|
        callback.call self, :init, ch

        ch.on_data do |c, data|
          EM.next_tick do
            @updated_at = Time.now
            session.queue.push [@key,nil,data]
          end
        end

        ch.on_extended_data do |c, type, data|
          EM.next_tick do
            @updated_at = Time.now
            session.queue.push [@key,type,data]
            LOG.debug [type,data]
          end
        end

        ch.on_request "exit-status" do |ch, data|
          EM.next_tick do
            @updated_at = Time.now
            session.queue.push [@key,:exit,data.read_long]
          end
        end

        ch.on_close do
          @updated_at = Time.now
          p "closed"
          callback.call self, :close
        end

        ch.on_open_failed do |ch, code, desc|
          EM.next_tick do
            callback.call self, :error, desc
          end
        end
      end

      @conn.open_channel do |ch|
        if session.interactive?
          ch.request_pty do |ch, success|
            ch.exec cmd do |ch, success|
              STDERR.puts "exec failed: #{cmd}" unless success
              setup[ch]
            end
          end
        else
          ch.exec cmd do |ch, success|
            STDERR.puts "exec failed: #{cmd}" unless success
            setup[ch]
          end
        end
      end
    end

    def old?
      @updated_at and Time.now - @updated_at > EXPIRE_INTERVAL
    end

    def free?
      @sessions.empty?
    end

    def connecting?
      @connecting
    end

    def dead?
      @failed_at
    end
  end

  class Session
    attr_reader :uuid, :queue
    @@sessions = {}

    def self.ids
      @@sessions.keys
    end

    def self.[](uuid)
      @@sessions[uuid] or raise KeyError, "no such session"
    end

    def interactive?
      @interactive
    end

    def initialize options, &callback
      keys = options[:keys]
      @interactive = !!options[:interactive]
      @uuid = SecureRandom.uuid
      @@sessions[@uuid] = self
      @keys = keys
      @connections = Hash[keys.map{|h| [h, Connection[h]]}]
      @connections.each_value{|h| h.bind self}
      @queue = EM::Queue.new
      @running = {}
      @dead = false
      @terminated = {}
    end

    def destroy
      LOG.debug "Destroying session #{@uuid}"
      p @running.map{|h,v| [h, v.class.name]}
      @running.each do |h,v| 
        if v.respond_to? :close
          p "Closing channel for #{h}"
          v.close
        end
      end
      @connections.each_value do |h| 
        callback h, :close, "user"
        h.unbind self
      end
      @dead = true
    end

    def destroy!
      @@sessions.delete @uuid
    end

    def done?
      @running.empty?
    end

    def dead?
      @dead
    end

    def run cmd
      dead = @connections.values.select(&:dead?)
      alive = @connections.values.reject(&:dead?)
      @queue.push [nil,:dead,dead.map(&:key)]
      alive.each { |h| @running[h.key] = true }
      alive.each do |h|
        h.run(cmd, self) { |h,e,c| callback h,e,c }
      end
    end

    def status
      {
        :children => Hash[@keys.map{|k| [k, 
          @terminated[k] ? :terminated :
          @running[k] == true ? :pending : 
          @running[k] ? :running : 
          @connections[k] ? 
            @connections[k].dead? ? :dead : :unknown
            : :done]}],
        :dead => @dead
      }
    end

    def << data
      @running.each do |k,v|
        if v.respond_to? :send_data
          v.send_data data
        end
      end
    end

    def terminate key
      chan = @running[key]
      conn = @connections[key]
      chan.close if chan.respond_to? :close
      if conn
        callback conn, :close, "user"
        conn.unbind self 
      end
      @running.delete key
      @connections.delete key
      @terminated[key] = true
    end

    def callback(h,e,c=nil)
      EM.next_tick do
        LOG.debug [h.key,e,c.nil?]
        case e
        when :init
          @queue.push [h.key,:start,nil]
          @running[h.key] = c
        when :close, :error
          h.unbind self unless @dead or not @connections.include? h.key
          @connections.delete h.key
          @queue.push [h.key,:dead,c] if e == :error
          @queue.push [h.key,:done,nil]
          @running.delete h.key
          if done?
            @queue.push [nil,:done,nil] 
            LOG.debug "run is done."
          else
            LOG.debug "#{@running.size} connections pending"
          end
        else
          LOG.error "Session#run: unexpected callback #{e}"
        end
      end
    end
  end
end

