require "rbconfig"

RSpec.describe Iodine::Perf do
  def fresh_ruby(code)
    lib = File.expand_path("../../lib", __dir__)
    IO.popen([RbConfig.ruby, "-I#{lib}", "-e", code], &:read).strip
  end

  # Fresh process per server example: on_state callbacks registered in one
  # example stay registered for the whole rspec process, and a stale one
  # could sleep or stop a later example's server. The server writes its ELU
  # result as "<idle> <elapsed>" lines to ELU_OUT_PATH; output is captured
  # for failure reports.
  def fresh_server_elu(task_code)
    out_path = File.join(Dir.tmpdir, "iodine-elu-#{Process.pid}-#{rand(1e9)}.txt")
    code = <<~RUBY
      require "iodine"
      Iodine::Perf.elu_enable_idle_time!
      Iodine.workers = 1

      Iodine.on_state(:on_start) do
        i0, e0 = Iodine::Perf.elu_snapshot

        #{task_code}

        Iodine.run_after(10_000) { Iodine.stop } # if the task above never runs
      end

      Iodine.start
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    output = IO.popen(
      [{ "ELU_OUT_PATH" => out_path }, RbConfig.ruby, "-I#{lib}", "-e", code],
      err: [:child, :out],
      &:read
    )
    raise "ELU server run failed:\n#{output}" unless File.exist?(out_path)
    File.read(out_path).lines.map(&:split).map { |l| l.map(&:to_i) }
  ensure
    File.delete(out_path) if out_path && File.exist?(out_path)
  end

  describe ".elu_enable_idle_time! / .elu_snapshot" do
    it "exposes the ELU API" do
      expect(Iodine::Perf).to respond_to(:elu_enable_idle_time!)
      expect(Iodine::Perf).to respond_to(:elu_snapshot)
    end

    it "accepts no arguments" do
      expect { Iodine::Perf.elu_enable_idle_time!(1) }.to raise_error(ArgumentError)
      expect { Iodine::Perf.elu_snapshot(1) }.to raise_error(ArgumentError)
    end

    it "returns nil when not enabled (fresh process)" do
      out = fresh_ruby('require "iodine"; p Iodine::Perf.elu_snapshot')
      expect(out).to eq("nil")
    end

    it "enable is idempotent and keeps the window" do
      Iodine::Perf.elu_enable_idle_time!
      _, e1 = Iodine::Perf.elu_snapshot
      expect(Iodine::Perf.elu_enable_idle_time!).to be(true)
      expect(Iodine::Perf.elu_snapshot[1]).to be >= e1
    end

    it "counters never decrease" do
      Iodine::Perf.elu_enable_idle_time!
      a = Iodine::Perf.elu_snapshot
      sleep 0.05
      b = Iodine::Perf.elu_snapshot
      expect(b[0]).to be >= a[0]
      expect(b[1]).to be > a[1]
    end

    it "accumulates idle while the loop waits" do
      idle_d, el_d = fresh_server_elu(<<~RUBY).first
        Iodine.run_after(600) do
          cur = Iodine::Perf.elu_snapshot
          File.write(ENV.fetch("ELU_OUT_PATH"),
                     [cur[0] - i0, cur[1] - e0].join(" "))
          Iodine.stop
        end
      RUBY
      expect(idle_d).to be > 0
      expect(idle_d).to be <= el_d
      # Mostly waiting: ELU well under 50%.
      expect(idle_d.to_f / el_d).to be > 0.5
    end

    it "does not count a blocked reactor as idle (ELU ~ 1)" do
      idle_d, el_d = fresh_server_elu(<<~RUBY).first
        Iodine.run do
          # Block the reactor: active time, not provider idle time.
          sleep 0.3
          cur = Iodine::Perf.elu_snapshot
          File.write(ENV.fetch("ELU_OUT_PATH"),
                     [cur[0] - i0, cur[1] - e0].join(" "))
          Iodine.stop
        end
      RUBY
      expect(el_d).to be >= 250_000_000
      expect(idle_d).to be < 100_000_000
      expect(1 - idle_d.to_f / el_d).to be > 0.7
    end

    # Regression: while the reactor sits inside a blocking wait, its unmatched
    # interval must be folded into reads as waiting in progress. Otherwise
    # cross-thread sampling reports full busy (idle static) and then dumps
    # the whole wait as one lump (ELU far below 0.0).
    it "reads consistently from a background thread while the reactor idles" do
      windows = fresh_server_elu(<<~RUBY)
        Thread.new do
          rows = []
          prev = Iodine::Perf.elu_snapshot
          12.times do
            sleep 0.05
            cur = Iodine::Perf.elu_snapshot
            rows << [cur[0] - prev[0], cur[1] - prev[1]].join(" ")
            prev = cur
          end
          File.write(ENV.fetch("ELU_OUT_PATH"), rows.join("\n"))
          Iodine.stop
        end
      RUBY
      raise "no ELU windows captured" if windows.empty?

      windows.each do |idle_d, el_d|
        expect(el_d).to be > 0
        expect(idle_d).to be >= 0
        # A single snapshot read can't overshoot elapsed by more than
        # clock/scheduling noise. (Full dumps overshoot by hundreds of ms.)
        expect(idle_d).to be <= el_d + 10_000_000
      end
      # The point of the in-progress fold-in: waiting time must actually be
      # visible to the sampler during those samples, not just bounded.
      expect(windows.any? { |idle_d, _| idle_d > 0 }).to be(true)
    end
  end
end
