# frozen_string_literal: true

File.binwrite('environment', Marshal.dump(ENV.to_hash)) if $PROGRAM_NAME == __FILE__
