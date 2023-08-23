# frozen_string_literal: true

require_relative 'lib/aibika'

Gem::Specification.new do |spec|
  spec.name          = 'aibika'
  spec.version       = Aibika::VERSION
  spec.authors       = ['Ribose Inc.']
  spec.email         = ['open.source@ribose.com']
  spec.license       = 'MIT'

  spec.summary = 'Ruby applications packager to a single executable on Windows'
  spec.description = <<~SUM
    Aibika packages a Ruby application into a single executable for the Windows
    platform.

    The resulting executable is self-extracting and self-running, containing:

    * the Ruby interpreter;
    * packaged Ruby source code; and
    * any additionally needed Ruby libraries or DLLs.

    NOTE: Aibika was created from the Metanorma-enhanced fork of the
    https://github.com/larsch/ocra[One-click Ruby Application "Ocra" packager].
    The first Aibkika version was launched as 1.3.12. The last version of Ocra
    was 1.3.11 from 2020.

    NOTE: Aibika is considered a temporary solution to the full-fledged
    functionality of https://github.com/tamatebako/tebako[Tebako], which provides a
    user-space mounted-disk experience with minimal intervention.

  SUM
  spec.homepage = 'https://github.com/tamatebako/aibika'
  spec.required_ruby_version = '>= 2.7.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/tamatebako/aibika'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files --recurse-submodules -z`.split("\x0").reject do |f|
      (f == __FILE__) ||
        f.match(%r{\A(?:(?:test)/|\.(?:git|cirrus|autotest|rubocop))})
    end
  end

  spec.bindir = 'bin'
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = %w[bin lib samples share src]
end
