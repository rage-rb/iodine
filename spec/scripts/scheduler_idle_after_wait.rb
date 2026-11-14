# Runs the reactor with one finished scheduler wait, then leaves unread data on
# the socket and prints the process CPU use while the reactor should be idle.
#
#   ruby -Ilib spec/scripts/scheduler_idle_after_wait.rb (zero|read|write|timeout|reattach)
require 'json'
require 'socket'
require 'iodine'

mode = ARGV.fetch(0)
reader, writer = Socket.pair(:UNIX, :STREAM, 0)
calls = []
result = nil

Iodine.threads = 1
Iodine.workers = 0

Iodine.on_state(:on_start) do
  events = mode == 'write' ? IO::WRITABLE : IO::READABLE
  timeout = { 'zero' => 0, 'read' => nil, 'write' => nil, 'timeout' => 1, 'reattach' => nil }.fetch(mode)
  on_ready = proc do |value|
    calls << value
    next unless mode == 'reattach' && calls.size == 1

    # Consume the first byte and wait on the same fd again, as a fiber reading in a loop does.
    reader.read_nonblock(1)
    Iodine::Scheduler.attach(reader.fileno, IO::READABLE, nil, &on_ready)
  end
  Iodine::Scheduler.attach(reader.fileno, events, timeout, &on_ready)

  # By now the wait has finished. Leave a byte on the socket that nobody reads.
  Iodine.run_after(mode == 'timeout' ? 2500 : 200) { writer.write_nonblock('x') }
  Iodine.run_after(300) { writer.write_nonblock('x') } if mode == 'reattach'

  Iodine.run_after(mode == 'timeout' ? 2700 : 400) do
    cpu_start = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Iodine.run_after(1000) do
      cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu_start
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_start
      result = {
        calls: calls,
        unread: reader.recv_nonblock(8, Socket::MSG_PEEK, exception: false),
        cpu_percent: (100 * cpu / wall).round(2)
      }
      Iodine.stop
    end
  end
end

Iodine.start
puts JSON.generate(result)
