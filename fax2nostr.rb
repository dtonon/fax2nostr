# host = "mail.yourprovider.com"
# username = "faxinbox@domain.com"
# password = "mailbox_password"
# nostr_prvkey = "hexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# nostr_npub = "npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# nostr_relays = ["wss://relay.nostr.ro", "wss://relay.wellorder.net", "wss://relay.snort.social", "wss://relay.damus.io"]

require 'mail'
require 'mini_magick'
require 'uri'
require 'net/http'
require 'securerandom'
require 'nostr_ruby'
require 'faye/websocket'
require 'eventmachine'

faxes = []

Mail.defaults do
  retriever_method :imap, {
    address: host,
    port: 993,
    user_name: username,
    password: password,
    enable_ssl: true
  }
end

unread_emails = Mail.find(keys: ['NOT','SEEN'])
puts "Found #{unread_emails.count} faxes!"
unread_emails.each do |email|

  if email.multipart?
    attachment = email.attachments.first
    next unless attachment.content_type.start_with?("application/pdf") || attachment.content_type.start_with?("application/octet-stream")
    pdf_in = "./fax.pdf"
    image_out = "./output.png"
    File.open(pdf_in, "wb") { |f| f.write(attachment.body.decoded) }
    
    pdf = MiniMagick::Image.open pdf_in
    MiniMagick::Tool::Convert.new do |convert|
      convert.background "white"
      convert.flatten
      convert.density 400
      convert.quality 100
      convert.resize  "50%"
      convert.modulate "98,100,100" # Reducing the brightness value a bit to show better on white bg
      convert << pdf.pages.first.path
      convert << "png8:#{image_out}"
    end
    
    this_fax = nil

    begin
      nostr_build_url = "http://nostr.build/upload.php"
      response = Net::HTTP.get_response(URI(nostr_build_url))
      if response.code.to_i >= 200 && response.code.to_i < 300
        boundary = SecureRandom.hex(10)
        uri = URI.parse("http://nostr.build/upload.php")
        post_body = []
        post_body << "--#{boundary}\r\n"
        post_body << "Content-Disposition: form-data; name='fileToUpload'; filename='#{File.basename(image_out)}'\r\n"
        post_body << "Content-Type: text/plain\r\n"
        post_body << "\r\n"
        post_body << File.read(image_out)
        post_body << "\r\n--#{boundary}--\r\n"
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Post.new(uri.request_uri)
        request.body = post_body.join
        request["Content-Type"] = "multipart/form-data, boundary=#{boundary}"
        response = http.request(request)
        match = response.body.match(/(https:\/\/nostr\.build\/i\/nostr\.build_.+)<\/b>/)
        this_fax = match[1]
        puts "Found => #{this_fax}"
      end
    rescue => e
      puts "#{nostr_build_url} => Error: #{e}"
    end

    faxes << this_fax && next if this_fax

    begin
      void_cat_url = "https://void.cat/upload?cli=true"
      response = Net::HTTP.get_response(URI(void_cat_url))
      if response.code.to_i >= 200 && response.code.to_i < 300
        uri = URI.parse(void_cat_url)
        http = Net::HTTP.new(uri.host, uri.port, use_ssl: true)
        request = Net::HTTP::Post.new(uri.request_uri)
        request["v-Filename"] = File.basename(image_out)
        request["v-Content-Type"] = "image/png"
        request.body = File.read(image_out)
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        this_fax = response.body.gsub("http", "https") + ".png"
        puts "Found => #{this_fax}"
      end
    rescue => e
      puts "#{void_cat_url} => Error: #{e}"
    end

    faxes << this_fax && next if this_fax

    raise "Upload services are down!"

  end
end

puts "Processing #{faxes.count} faxes"
n = Nostr.new(private_key: nostr_prvkey)

faxes.each do |fax|

  content = fax
  content << "\n\nThis note has been posted on Nostr by fax :)"
  event = n.build_note_event(content)
  puts event.inspect

  nostr_relays.each do |relay|

    puts relay
    timer = 0
    response = nil
    timer_step = 0.1
    timeout = 3

    begin
      ws = WebSocket::Client::Simple.connect relay
      ws.on :message do |msg|
        puts msg
        response = JSON.parse(msg.data)
        ws.close if response[0] == 'OK'
      end
      ws.on :open do
        ws.send event.to_json
      end
      while timer < timeout && response.nil? do
        sleep timer_step
        timer += timer_step
      end
      ws.close
    rescue => e
      puts e.inspect
      ws.close
    end

  end

end