# frozen_string_literal: true

# Ask the AI accountant one question and print the answer.
#
#   TUNGO_API_KEY=tg_... TUNGO_COMPANY_ID=co_... ruby examples/ask.rb "Сколько НДС к уплате?"

require "tungo"

client = Tungo::Client.new
question = ARGV.first || "Покажи дебиторку за октябрь"

begin
  result = client.ask(question)
  puts result.answer
  puts "dialog #{result.dialog_id}, request #{result.api_response.request_id}"
rescue Tungo::LimitError => e
  warn "Limit reached (#{e.code}): #{e.api_message}"
  exit 1
rescue Tungo::APIError => e
  warn "API error #{e.status} #{e.type}: #{e.api_message} (request #{e.request_id})"
  exit 1
ensure
  client.close
end
