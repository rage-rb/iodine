require "json"
require "digest"

module Rage
  UploadedFile = Struct.new(:file, :original_filename, :content_type)
end

run ->(env) do
  params = Iodine::Rack::Utils.parse_multipart(env["rack.input"], env["CONTENT_TYPE"])
  
  file_key, file = params.find { |_, v| v.is_a?(Rage::UploadedFile) }
  params["#{file_key}_digest"] = Digest::MD5.hexdigest(file.file.read)

rescue => e
  [500, {}, [e.message]]
else
  [200, { "content-type" => "application/json" }, [JSON.dump(params)]]
end
