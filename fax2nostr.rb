# fax_number = "+39000010101010"
# host = "mail.yourprovider.com"
# username = "faxinbox@domain.com"
# password = "mailbox_password"
# nostr_prvkey = "hexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# nostr_npub = "npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# nostr_relays = ["wss://relay.nostr.ro", "wss://relay.wellorder.net", "wss://relay.snort.social", "wss://relay.damus.io"]

require 'mail'
require 'rmagick'
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
unread_emails.each do |email|

  if email.multipart?
    attachment = email.attachments.first
    next unless attachment.content_type.start_with?("application/pdf") || attachment.content_type.start_with?("application/octet-stream")
    pdf_in = "./file.pdf"
    image_out = "./output.png"
    File.open(pdf_in, "wb") { |f| f.write(attachment.body.decoded) }
    
    pdf = Magick::Image.read(pdf_in)
    pdf[0].border!(0, 0, 'white')
    pdf[0].alpha Magick::DeactivateAlphaChannel
    pdf[0].write(image_out)

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
    if match
      puts "Found => #{match[1]}"
      faxes << match[1]
    end
  end
end

puts "Processing #{faxes.count} faxes"
n = Nostr.new(private_key: nostr_prvkey)

faxes.each do |fax|

  content = fax
  content << "\n\nPowered by fax2nostr\nSend a fax to #{fax_number} to publish it on Nostr\nFollow the feed: @#{nostr_npub}"
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
    rescue => e
      puts e.inspect
    end

  end

end