require 'spec_helper'

RSpec.describe 'Iodine::Base::RackStream' do
  it 'is defined under Iodine::Base' do
    expect(defined?(Iodine::Base::RackStream)).to eq('constant')
  end

  it 'exposes the writer and wake-channel API' do
    expect(Iodine::Base::RackStream.instance_methods(false)).to include(
      :write, :close, :closed?, :wake_channel
    )
  end
end
