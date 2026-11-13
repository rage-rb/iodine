require 'json'
require 'open3'
require 'rbconfig'

RSpec.describe 'Iodine::Scheduler after a wait finishes' do
  def run_idle_after_wait(mode)
    out, err, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', 'spec/scripts/scheduler_idle_after_wait.rb', mode
    )
    expect(status).to be_success, err
    JSON.parse(out.lines.last)
  end

  # A finished wait must not keep the fd armed: data that arrives later and is
  # never read would otherwise wake the reactor on every loop pass.
  {
    'zero' => [false],                      # timeout 0, e.g. Net::HTTP's keep-alive check
    'read' => [nil],                        # read wait that completed
    'write' => [nil],                       # write-only wait
    'timeout' => [-Errno::ETIMEDOUT::Errno], # finite timeout that expired
    'reattach' => [nil, nil] # a second wait on the same fd still gets its data
  }.each do |mode, expected_calls|
    it "keeps the reactor idle after a #{mode} wait" do
      result = run_idle_after_wait(mode)

      expect(result['calls']).to eq(expected_calls)
      expect(result['unread']).to eq('x')
      expect(result['cpu_percent']).to be < 20
    end
  end
end
