require "benchmark"

RSpec.describe "Thread waking up reactor" do
  def within_reactor(&block)
    fiber, expectation = nil

    Iodine.defer do
      fiber = Fiber.new { expectation = block.call }
      fiber.resume
    end

    Iodine.run_every(1_000) { Iodine.stop unless fiber.alive? rescue Iodine.stop }
    Iodine.run_after(10_000) { fiber.raise("execution expired") }

    Iodine.threads = Iodine.workers = 1
    Iodine.start

    expectation.call
  end

  context "with defer" do
    it "wakes up the reactor from a non-reactor thread" do
      within_reactor do
        f = Fiber.current
        Thread.new { Iodine.defer { f.resume } }

        time = Benchmark.realtime { Fiber.yield } * 1_000
        -> { expect(time).to be < 10 }
      end
    end
  end

  context "with publish" do
    it "wakes up the reactor from a non-reactor thread" do
      within_reactor do
        f = Fiber.current
        Iodine.subscribe("wake up") { f.resume }

        Thread.new do
          Thread.pass
          Iodine.publish("wake up", "")
        end

        time = Benchmark.realtime { Fiber.yield } * 1_000
        -> { expect(time).to be < 10 }
      end
    end
  end
end
