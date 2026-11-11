# frozen_string_literal: true

# List the companies of the key, then walk over every proposal of the default company.
#
#   TUNGO_API_KEY=tg_... TUNGO_COMPANY_ID=co_... ruby examples/paginate.rb

require "tungo"

client = Tungo::Client.new
client.companies.list.data.each { |company| puts "#{company.id} #{company.name}" }

client.proposals.list_all(limit: 50).each do |proposal|
  puts "#{proposal.id} #{proposal.title} #{proposal.total&.formatted}"
end
client.close
