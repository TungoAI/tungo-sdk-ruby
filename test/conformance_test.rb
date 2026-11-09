# frozen_string_literal: true

require_relative '../lib/tungo'

raise 'money failed' unless Tungo::Money.to_tiyn(45_000) == 4_500_000
raise 'format failed' unless Tungo::Money.format_tiyn(4_500_000) == '45 000,00 ₸'
