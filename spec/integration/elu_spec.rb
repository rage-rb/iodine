require "http"
require "socket"
require "timeout"

RSpec.describe "Event loop utilization" do
  include Spec::Support::IodineServer

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def get(port, path)
    HTTP.timeout(2).get("http://127.0.0.1:#{port}#{path}")
  end

  def wait_ready(port)
    30.times do
      begin
        Socket.tcp("127.0.0.1", port, connect_timeout: 1) {}
        return
      rescue SystemCallError
        sleep 0.2
      end
    end
    raise "ELU test server did not come up on #{port}"
  end

  # Unique port per spawn: never cross-talk with stale servers.
  def with_elu_server(workers:)
    port = free_port
    cmd = "bundle exec exe/iodine -w #{workers} -t 1 -p #{port}"
    pid = spawn_with_test_log("RSPEC_TEST_ENV=1 #{cmd} spec/support/apps/elu.ru")
    wait_ready(port)
    begin
      yield port
    ensure
      begin
        Process.kill("SIGINT", pid)
      rescue SystemCallError
        nil
      end
      begin
        Timeout.timeout(15) { Process.wait(pid) }
      rescue Timeout::Error, SystemCallError
        begin
          Process.kill("KILL", pid)
        rescue SystemCallError
          nil
        end
      end
    end
  end

  def elu_sample(port)
    [get(port, "/idle").body.to_s.to_i, get(port, "/elapsed").body.to_s.to_i]
  end

  it "accumulates idle while the loop waits" do
    with_elu_server(workers: 1) do |port|
      i0, e0 = elu_sample(port)
      sleep 0.6
      i1, e1 = elu_sample(port)
      idle_d, el_d = i1 - i0, e1 - e0
      expect(idle_d).to be > 0
      # Independent HTTP reads sample slightly different instants, so allow
      # a small epsilon: a real over-counting bug would show hundreds of ms.
      expect(idle_d).to be <= el_d + 25_000_000
      # Mostly waiting: ELU well under 50%.
      expect(idle_d.to_f / el_d).to be > 0.5
    end
  end

  it "does not count a blocked reactor as idle (ELU ~ 1)" do
    with_elu_server(workers: 1) do |port|
      i0, e0 = elu_sample(port)
      expect(get(port, "/block").body.to_s).to eq("blocked")
      i1, e1 = elu_sample(port)
      idle_d, el_d = i1 - i0, e1 - e0
      expect(el_d).to be >= 250_000_000
      expect(idle_d).to be < 100_000_000
      expect(1 - idle_d.to_f / el_d).to be > 0.7
    end
  end

  it "serves traffic with the probe enabled and stays consistent" do
    with_elu_server(workers: 1) do |port|
      20.times do
        expect(get(port, "/").body.to_s).to eq("ok")
      end
      i0, e0 = elu_sample(port)
      sleep 0.3
      i1, e1 = elu_sample(port)
      expect(e1 - e0).to be > 0
      expect(i1 - i0).to be >= 0
      # Same independent-read epsilon as above.
      expect(i1 - i0).to be <= (e1 - e0) + 25_000_000
    end
  end

  it "restarts the window in forked workers" do
    with_elu_server(workers: 2) do |port|
      readings = 6.times.map { get(port, "/elapsed").body.to_s.to_i }
      # The parent window aged 0.6s before forking; fresh worker windows
      # read milliseconds. Without a reset every reading would be >= 0.6s.
      expect(readings).to all(be > 0)
      expect(readings).to all(be < 400_000_000)
    end
  end
end
