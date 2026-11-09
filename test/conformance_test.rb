# frozen_string_literal: true

require_relative '../lib/tungo'

raise 'money failed' unless Tungo::Money.to_tiyn(45_000) == 4_500_000
raise 'format failed' unless Tungo::Money.format_tiyn(4_500_000) == '45 000,00 ₸'
raise 'bin_iin valid failed' unless Tungo::Money.valid_bin_iin?('990140000017')
raise 'bin_iin valid pass2 failed' unless Tungo::Money.valid_bin_iin?('991140000015')
raise 'bin_iin invalid failed' if Tungo::Money.valid_bin_iin?('990140000016')
sig = Tungo::Webhooks.sign_hook_payload('{"ok":true}', 'sec')
raise 'hook sig failed' unless Tungo::Webhooks.verify_hook_signature('{"ok":true}', sig, 'sec')
raise 'hook sig raw failed' unless Tungo::Webhooks.verify_hook_signature('{"ok":true}', sig.sub('sha256=', ''), 'sec')
