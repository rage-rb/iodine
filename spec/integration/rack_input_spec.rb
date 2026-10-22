# frozen_string_literal: true

RSpec.describe "rack.input", with_app: :rack_input do
  it "invalidates the output buffer coderange after replacing its contents" do
    body = ("a" * 64).b << "\xFF".b

    response = http_post("/", body: body)

    expect(response.status).to eq(200)
    expect(response.body.to_s).to eq("ASCII-8BIT:false:65")
  end
end
