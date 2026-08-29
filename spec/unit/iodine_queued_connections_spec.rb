require "socket"

RSpec.describe Iodine do
  describe '.queued_connections' do
    before(:all) do
      skip "Linux only (TCP_INFO)" unless RUBY_PLATFORM.include?("linux")
    end

    def free_port
      s = TCPServer.new("127.0.0.1", 0)
      port = s.addr[1]
      s.close
      port
    end

    it 'returns an Integer' do
      expect(Iodine.queued_connections).to be_a(Integer)
    end

    it 'accepts no arguments' do
      expect { Iodine.queued_connections(3000) }.to raise_error(ArgumentError)
    end

    it 'returns 0 when no iodine listeners exist' do
      expect(Iodine.queued_connections).to eq(0)
    end

    it 'reports the accept queue of its own listeners' do
      port = free_port
      result = nil
      Iodine.workers = 1
      Iodine.on_state(:on_start) do
        t = Thread.new { 5.times.map { TCPSocket.new("127.0.0.1", port) } }
        socks = t.value
        Iodine.run { result = Iodine.queued_connections }
        socks.each(&:close)
        Iodine.run { Iodine.stop }
      end
      Iodine.listen(:port => port, :handler => Proc.new { [200, {}, ["ok"]] })
      Iodine.start
      expect(result).to eq(5)
    end

    it 'counts only iodine-owned listeners, not raw sockets' do
      raw_port = free_port
      iodine_port = free_port
      raw = TCPServer.new("127.0.0.1", raw_port)
      result = nil
      Iodine.workers = 1
      Iodine.on_state(:on_start) do
        t = Thread.new { 5.times.map { TCPSocket.new("127.0.0.1", raw_port) } }
        socks = t.value
        Iodine.run { result = Iodine.queued_connections }
        socks.each(&:close)
        Iodine.run { Iodine.stop }
      end
      Iodine.listen(:port => iodine_port, :handler => Proc.new { [200, {}, ["ok"]] })
      Iodine.start
      raw.close
      expect(result).to eq(0)
    end

    it 'sums the queues of all iodine listeners' do
      port1 = free_port
      port2 = free_port
      result = nil
      Iodine.workers = 1
      Iodine.on_state(:on_start) do
        t1 = Thread.new { 3.times.map { TCPSocket.new("127.0.0.1", port1) } }
        t2 = Thread.new { 2.times.map { TCPSocket.new("127.0.0.1", port2) } }
        s1, s2 = t1.value, t2.value
        Iodine.run { result = Iodine.queued_connections }
        s1.each(&:close)
        s2.each(&:close)
        Iodine.run { Iodine.stop }
      end
      Iodine.listen(:port => port1, :handler => Proc.new { [200, {}, ["ok"]] })
      Iodine.listen(:port => port2, :handler => Proc.new { [200, {}, ["ok"]] })
      Iodine.start
      expect(result).to eq(5)
    end
  end
end