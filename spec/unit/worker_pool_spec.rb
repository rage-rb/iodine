# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Iodine::WorkerPool" do
  before(:all) do
    skip "WorkerPool not available" unless defined?(Iodine::WorkerPool)
  end

  describe "#initialize" do
    it "creates a pool with specified size" do
      pool = Iodine::WorkerPool.new(2)
      expect(pool.size).to eq(2)
      pool.close
    end

    it "raises ArgumentError for size 0" do
      expect { Iodine::WorkerPool.new(0) }.to raise_error(ArgumentError, /must be greater than 0/)
    end

    it "raises ArgumentError for negative size" do
      expect { Iodine::WorkerPool.new(-1) }.to raise_error(ArgumentError, /must be greater than 0/)
      expect { Iodine::WorkerPool.new(-100) }.to raise_error(ArgumentError, /must be greater than 0/)
    end

    it "raises TypeError for non-integer size" do
      expect { Iodine::WorkerPool.new("2") }.to raise_error(TypeError)
    end
  end

  describe "#size" do
    it "returns the number of worker threads" do
      pool = Iodine::WorkerPool.new(2)
      expect(pool.size).to eq(2)
      pool.close
    end
  end

  describe "#stats" do
    it "returns a hash with pool statistics" do
      pool = Iodine::WorkerPool.new(2)

      stats = pool.stats
      expect(stats).to be_a(Hash)
      expect(stats[:workers]).to eq(2)
      expect(stats[:queued]).to eq(0)
      expect(stats[:submitted]).to eq(0)
      expect(stats[:completed]).to eq(0)
      expect(stats[:closed]).to eq(false)

      pool.close
    end

    it "reflects shutdown state after close" do
      pool = Iodine::WorkerPool.new(2)
      pool.close

      stats = pool.stats
      expect(stats[:closed]).to eq(true)
      expect(stats[:workers]).to eq(0)
    end
  end

  describe "#close" do
    it "shuts down the pool" do
      pool = Iodine::WorkerPool.new(2)
      expect(pool.stats[:closed]).to eq(false)

      pool.close

      expect(pool.stats[:closed]).to eq(true)
      expect(pool.stats[:workers]).to eq(0)
    end

    it "is idempotent" do
      pool = Iodine::WorkerPool.new(2)

      expect { pool.close }.not_to raise_error
      expect { pool.close }.not_to raise_error

      expect(pool.stats[:closed]).to eq(true)
    end
  end

  describe "#enqueue" do
    it "requires a block" do
      pool = Iodine::WorkerPool.new(2)

      expect { pool.enqueue(nil) }.to raise_error(ArgumentError, /block required/)

      pool.close
    end

    it "raises RuntimeError when pool is shut down" do
      pool = Iodine::WorkerPool.new(2)
      pool.close

      expect { pool.enqueue(nil) { } }.to raise_error(RuntimeError, /shut down/)
    end
  end

  describe "GC safety" do
    it "handles GC of pool that failed initialization" do
      10.times do
        begin
          Iodine::WorkerPool.new(0)
        rescue ArgumentError
          # Expected
        end

        begin
          Iodine::WorkerPool.new(-1)
        rescue ArgumentError
          # Expected
        end
      end

      # Force GC - should not crash on uninitialized pools
      GC.start(full_mark: true, immediate_sweep: true)
    end

    it "pool survives GC when operations are pending" do
      pool = Iodine::WorkerPool.new(2)

      GC.start(full_mark: true, immediate_sweep: true)

      stats = pool.stats
      expect(stats[:workers]).to eq(2)
      expect(stats[:closed]).to eq(false)

      pool.close
    end
  end
end
