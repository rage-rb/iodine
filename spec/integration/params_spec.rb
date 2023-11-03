# frozen_string_literal: true

RSpec.describe Iodine::Rack::Utils do
  describe "#parse_nested_query" do
    subject { described_class.parse_nested_query(q) }

    context "with one plain param" do
      let(:q) { "name=ross" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross" })
      end
    end

    context "with multiple plain params" do
      let(:q) { "name=ross&occupation=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", occupation: "paleontologist" })
      end
    end

    context "with array" do
      let(:q) { "names[]=ross&names[]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ names: %w(ross chandler) })
      end
    end

    context "with hash" do
      let(:q) { "users[name]=ross" }

      it "works correctly" do
        expect(subject).to eq({ users: { name: "ross" } })
      end
    end

    context "with hash with multiple values" do
      let(:q) { "users[name]=ross&users[occupation]=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ users: { name: "ross", occupation: "paleontologist" } })
      end
    end

    context "with nested arrays" do
      let(:q) { "users[][]=ross&users[][]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [%w(ross), %w(chandler)] })
      end
    end

    context "with hash nested inside array" do
      let(:q) { "users[][name]=ross" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ name: "ross" }] })
      end
    end

    context "with longer hash nested inside array" do
      let(:q) { "users[][name]=ross&users[][name]=chandler&users[][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ name: "ross" }, { name: "chandler" }, { name: "joey" }] })
      end
    end

    context "with array nested inside hash" do
      let(:q) { "ross[friends][]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: %w(chandler) } })
      end
    end

    context "with longer array nested inside hash" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[friends][]=monica" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: %w(chandler joey monica) } })
      end
    end

    context "with array nested inside multiple hashes" do
      let(:q) { "users[ross][friends][]=chandler&users[ross][friends][]=chandlers-mom" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: { friends: %w(chandler chandlers-mom) } } })
      end
    end

    context "with hash nested inside hash" do
      let(:q) { "ross[friend][name]=chandler&chandler[friend][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friend: { name: "chandler" } }, chandler: { friend: { name: "joey" } } })
      end
    end

    context "with mixed types" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ users: { user: { id: "11", name: "ross", friends: [{ id: "22", name: "chandler" }, { id: "33", name: "joey" }] } } })
      end
    end

    context "with hash with repeated attributes nested inside array" do
      let(:q) { "users[][id]=11&users[][name]=ross&users[][id]=22&users[][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ id: "11", name: "ross" }, { id: "22", name: "chandler" }] })
      end
    end

    context "with hash with mixed attributes nested inside array" do
      let(:q) { "users[][id]=11&users[][name]=ross&users[][id]=22&users[][full_name]=chandler-bing" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ id: "11", name: "ross" }, { id: "22", full_name: "chandler-bing" }] })
      end
    end

    context "with multi-level hash with mixed attributes nested inside array" do
      let(:q) { "users[][data][id]=11&users[][data][name]=ross&users[][data][id]=22&users[][data][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end

    context "with blank values" do
      let(:q) { "users=" }

      it "works correctly" do
        expect(subject).to eq({ users: "" })
      end
    end

    context "with blank array values" do
      let(:q) { "users[]" }

      it "works correctly" do
        expect(subject).to eq({ users: [""] })
      end
    end

    context "with blank hash values" do
      let(:q) { "users[ross]" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: "" } })
      end
    end

    context "with no values" do
      let(:q) { "users" }

      it "works correctly" do
        expect(subject).to eq({ users: nil })
      end
    end

    context "with overlapping params" do
      let(:q) { "name=ross&name=chandler" }

      it "works correctly" do
        expect(subject).to eq({ name: "chandler" })
      end
    end

    context "with missing params" do
      let(:q) { "name=ross&age=" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", age: "" })
      end
    end

    context "with overlapping and missing params" do
      let(:q) { "name&name=" }

      it "works correctly" do
        expect(subject).to eq({ name: "" })
      end
    end

    context "with encoded values" do
      let(:q) { "ross=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ ross: "m@rried 5 time$" })
      end
    end

    context "with array encoded values" do
      let(:q) { "ross[]=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ ross: ["m@rried 5 time$"] })
      end
    end

    context "with hash encoded values" do
      let(:q) { "users[ross]=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: "m@rried 5 time$" } })
      end
    end

    context "with no array values" do
      let(:q) { "names[]" }

      it "works correctly" do
        expect(subject).to eq({ names: [""] })
      end
    end

    context "with blank array values" do
      let(:q) { "names[]=" }

      it "works correctly" do
        expect(subject).to eq({ names: [""] })
      end
    end

    context "with missing array values" do
      let(:q) { "names[]=ross&occupation" }

      it "works correctly" do
        expect(subject).to eq({ names: ["ross"], occupation: nil })
      end
    end

    context "with missing array values" do
      let(:q) { "occupation&names[]=ross" }

      it "works correctly" do
        expect(subject).to eq({ occupation: nil, names: ["ross"] })
      end
    end

    context "with missing array specifiers" do
      let(:q) { "names[]=ross&names[=chandler" }

      it "raises an error" do
        expect { subject }.to raise_error("Bad params")
      end
    end

    context "with missing array specifiers and blank values" do
      let(:q) { "names[]=ross&names[=" }

      it "raises an error" do
        expect { subject }.to raise_error("Bad params")
      end
    end

    context "with mixed plain and array params" do
      let(:q) { "name=ross&friends[]=1&friends[]=2&friends[]=3" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", friends: %w(1 2 3) })
      end
    end

    context "with nested hashes and missing values" do
      let(:q) { "user[ross][occupation]" }

      it "works correctly" do
        expect(subject).to eq({ user: { ross: { occupation: "" } } })
      end
    end

    context "with nested hashes and blank values" do
      let(:q) { "user[ross][occupation]=" }

      it "works correctly" do
        expect(subject).to eq({ user: { ross: { occupation: "" } } })
      end
    end

    context "with array surrounded by hash" do
      let(:q) { "ross[friends][][id]=1" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1" }] } })
      end
    end

    context "with changing types" do
      let(:q) { "users[ross][][friends][]=10" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: [{ friends: ["10"] }] } })
      end
    end

    context "with multiple arrays surrounded by hash" do
      let(:q) { "ross[friends][][id]=1&ross[friends][][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1", name: "chandler" }] } })
      end
    end

    context "mixed arrays and hashes" do
      let(:q) { "ross[wives][][third][id]=123" }

      it "works correctly" do
        expect(subject).to eq({ ross: { wives: [{ third: { id: "123" } }] } })
      end
    end

    context "plain keys inside [] and nested hashes" do
      let(:q) { "[ross][][friends]=1&ross[friends][][data][id]=2" }

      it "works correctly" do
        expect(subject).to eq({ "[ross]": [{ friends: "1" }], ross: { friends: [{ data: { id: "2" } }] } })
      end
    end

    context "plain keys inside [] and nested hashes" do
      let(:q) { "[ross][][friends]=1&ross[friends][][data][id]=2" }

      it "works correctly" do
        expect(subject).to eq({ "[ross]": [{ friends: "1" }], ross: { friends: [{ data: { id: "2" } }] } })
      end
    end

    context "with multiple arrays surrounded by hashes with same keys" do
      let(:q) { "ross[friends][][id]=1&ross[friends][][id]=222" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1" }, { id: "222" }] } })
      end
    end

    context "with nested hashes with repeated keys" do
      let(:q) { "friends[data][][friends][name]=ross&friends[data][][friends][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: { data: [{ friends: { name: "ross" } }, { friends: { name: "joey" } }] } })
      end
    end

    context "with nested hashes with rotating keys" do
      let(:q) { "friends[data][][id]=1&friends[data][][name]=ross&friends[data][][id]=22&friends[data][][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: { data: [{ id: "1", name: "ross" }, { id: "22", name: "joey" }] } })
      end
    end

    context "with nested hashes with rotating keys inside array" do
      let(:q) { "friends[][id]=1&friends[][dob][year]=1967&friends[][id]=2&friends[][dob][year]=1968" }

      it "works correctly" do
        expect(subject).to eq({ friends: [{ id: "1", dob: { year: "1967" } }, { id: "2", dob: { year: "1968" } }] })
      end
    end

    context "with nested hashes with rotating keys inside array" do
      let(:q) { "friends[][id]=1&friends[][name]=ross&friends[][idd]=2&friends[][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: [{ id: "1", name: "ross", idd: "2" }, { name: "joey" }] })
      end
    end

    context "with deep nested hashes with rotating keys" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][name]=ross&users[][data][attrs][id]=22&users[][data][attrs][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11", name: "ross" } } }, { data: { attrs: { id: "22", name: "chandler" } } }] })
      end
    end

    context "with deep nested hashes with rotating keys in different order" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][name]=ross&users[][data][attributes][id]=22&users[][data][attributes][id]=33&users[][data][attrs][id]=22&users[][data][attrs][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11", name: "ross" }, attributes: { id: "22" } } }, { data: { attributes: { id: "33" }, attrs: { id: "22", name: "chandler" } } }] })
      end
    end

    context "with nested hashes inside an array" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][id]=22" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11" } } }, { data: { attrs: { id: "22" } } }] })
      end
    end

    context "with different keys inside nested structures" do
      let(:q) { "users[][data][id1]=1&users[][data][id2]=3" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id1: "1", id2: "3" } }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][id]=1&x[][y][a]=5&x[][y][b]=7&x[][z][id]=3&x[][z][w]=0&x[][id]=2&x[][y][a]=6&x[][y][b]=8&x[][z][id]=4&x[][z][w]=0" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ id: "1", y: { a: "5", b: "7" }, z: { id: "3", w: "0" } }, { id: "2", y: { a: "6", b: "8" }, z: { id: "4", w: "0" } }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][z][w]=a&x[][y]=1&x[][z][w]=b&x[][y]=2" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ z: { w: "a" }, y: "1" }, { z: { w: "b" }, y: "2" }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][y]=1&x[][z][w]=a&x[][y]=2&x[][z][w]=b" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ z: { w: "a" }, y: "1" }, { z: { w: "b" }, y: "2" }] })
      end
    end

    context "with deep params" do
      let(:q) { "friends[][][data][][id][]=1" }

      it "raises an error" do
        expect { subject }.to raise_error("Params too deep")
      end
    end

    context "with incorrect params" do
      let(:q) { "a[]=1&a[b]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a[b]=1&a[]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a=1&a[]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a=1&a[b]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[][]=ross&users[][name]=chandler" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[friends][name]=monica" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[]=monica" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][attrs][name]=joey" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][name]=joey" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][id][name]=ross" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end
  end

  describe "#parse_urlencoded_nested_query" do
    subject { described_class.parse_urlencoded_nested_query(q) }

    context "with unencoded plain params" do
      let(:q) { "name=ross&occupation=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", occupation: "paleontologist" })
      end
    end

    context "with encoded plain params" do
      let(:q) { "name%3Dross%26occupation%3Dpaleontologist" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", occupation: "paleontologist" })
      end
    end

    context "unencoded complex params" do
      let(:q) { "users[][data][id]=11&users[][data][name]=ross&users[][data][id]=22&users[][data][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end

    context "encoded complex params" do
      let(:q) { "users%5B%5D%5Bdata%5D%5Bid%5D%3D11%26users%5B%5D%5Bdata%5D%5Bname%5D%3Dross%26users%5B%5D%5Bdata%5D%5Bid%5D%3D22%26users%5B%5D%5Bdata%5D%5Bname%5D%3Dchandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end
  end

  describe "#parse_multipart", with_app: :params do
    subject { described_class.parse_multipart(q) }

    context "with a file" do
      let(:file) do
        Tempfile.new.tap do |f|
          f.write "hello\nworld\0\xF0\x9F\x98\x80"
          f.rewind
        end
      end

      it "works correctly" do
        response = http_post("/", form: {
          message: HTTP::FormData::File.new(file.path)
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["message_digest"]).to eq("9f18eb0338a94b5306cf6ab104ada8c8")
      end
    end

    context "with params" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        response = http_post("/", form: {
          count: 1,
          avatar: HTTP::FormData::File.new(file.path),
          "users[user][id]" => 11,
          "users[user][name]" => "ross",
          "users[user][friends][][id]" => 22,
          "users[user][friends][][name]" => "chandler"
        })

        expect(response.status.to_i).to eq(200)
        parsed = response.parse
        expect(parsed["users"]).to eq({ "user" => { "id" => "11", "name" => "ross", "friends" => [{ "id" => "22", "name" => "chandler" }] } })
        expect(parsed["count"]).to eq("1")
        expect(parsed["avatar_digest"]).to eq("d41d8cd98f00b204e9800998ecf8427e")
      end
    end

    context "with malformed params" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        response = http_post("/", form: {
          "file" => HTTP::FormData::File.new(file.path),
          "param[" => "test"
        })

        expect(response.status.to_i).to eq(500)
        expect(response.body.to_s).to eq("Bad params")
      end
    end

    context "with malformed body" do
      it "works correctly" do
        response = http_post("/", form: { "param[" => "test" })

        expect(response.status.to_i).to eq(500)
        expect(response.body.to_s).to eq("Malformed multipart request")
      end
    end

    context "with a file bigger than one block" do
      let(:file) do
        Tempfile.new.tap do |f|
          f.write "1" * 300_000
          f.rewind
        end
      end

      it "works correctly" do
        response = http_post("/", form: {
          f: HTTP::FormData::File.new(file.path)
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["f_digest"]).to eq("4bc18f32f2f14a84890b5680ffeb2cbb")
      end
    end

    context "with a parameter bigger than one block" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        string = rand(10).to_s * 300_000

        response = http_post("/", form: {
          file: HTTP::FormData::File.new(file.path),
          parameter: string
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["parameter"]).to eq(string)
      end
    end
  end
end
