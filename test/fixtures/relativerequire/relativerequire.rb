# frozen_string_literal: true

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'somedir/somefile'
require 'SomeDir/otherfile'
exit 160 if (__FILE__ == $PROGRAM_NAME) && defined?(SOME_CONST) && defined?(OTHER_CONST)
