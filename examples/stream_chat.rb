# frozen_string_literal: true

# Stream a chat turn and print the text as it arrives.
#
#   TUNGO_API_KEY=tg_... TUNGO_COMPANY_ID=co_... ruby examples/stream_chat.rb

require "tungo"

client = Tungo::Client.new
stream = client.chat.create_stream(message: ARGV.first || "Сколько НДС к уплате за III квартал?")
turn = stream.each_text { |delta| print delta }
puts
puts "dialog #{turn.dialog_id}, turn #{turn.turn_no}, stop reason #{turn.stop_reason}"
client.close
