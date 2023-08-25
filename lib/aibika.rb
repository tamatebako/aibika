# frozen_string_literal: true

require_relative 'aibika/aibika_builder'
require_relative 'aibika/cli'
require_relative 'aibika/host'
require_relative 'aibika/library_detector'
require_relative 'aibika/pathname'
require_relative 'aibika/version'

module Aibika
  # Fence against packaging of self (aibika gem) unless implicitly requestd
  # String, NilClass and arrays of any of these.
  def self.fence_self?(name)
    !Aibika.allow_self && name == 'aibika'
  end

  def self.fence_self_dir?(dir)
    !Aibika.allow_self && dir.start_with?(__dir__)
  end

  # Type conversion for the Pathname class. Works with Pathname,
  # String, NilClass and arrays of any of these.
  def self.Pathname(obj)
    case obj
    when Pathname
      obj
    when Array
      obj.map { |x| Pathname(x) }
    when String
      Pathname.new(obj)
    when NilClass
      nil
    else
      raise ArgumentError, obj
    end
  end

  # Sorts and returns an array without duplicates. Works with complex
  # objects (such as Pathname), in contrast to Array#uniq.
  def self.sort_uniq(arr)
    arr.sort.inject([]) { |r, e| r.last == e ? r : r << e }
  end

  IGNORE_MODULE_NAMES = %r{/(enumerator.so|rational.so|complex.so|fiber.so|thread.rb|ruby2_keywords.rb)$}.freeze

  GEM_SCRIPT_RE = /\.rbw?$/.freeze
  GEM_EXTRA_RE = %r{(
    # Auxiliary files in the root of the gem
    ^(\./)?(History|Install|Manifest|README|CHANGES|Licen[sc]e|Contributors|ChangeLog|BSD|GPL).*$ |
    # Installation files in the root of the gem
    ^(\./)?(Rakefile|setup.rb|extconf.rb)$ |
    # Documentation/test directories in the root of the gem
    ^(\./)?(doc|ext|examples|test|tests|benchmarks|spec)/ |
    # Directories anywhere
    (^|/)(\.autotest|\.svn|\.cvs|\.git)(/|$) |
    # Unlikely extensions
    \.(rdoc|c|cpp|c\+\+|cxx|h|hxx|hpp|obj|o|a)$/
  )}xi.freeze

  GEM_NON_FILE_RE = /(#{GEM_EXTRA_RE}|#{GEM_SCRIPT_RE})/.freeze

  # Alias for the temporary directory where files are extracted.
  TEMPDIR_ROOT = Pathname.new('|')
  # Directory for source files in temporary directory.
  SRCDIR = Pathname.new('src')
  # Directory for Ruby binaries in temporary directory.
  BINDIR = Pathname.new('bin')
  # Directory for GEMHOME files in temporary directory.
  GEMHOMEDIR = Pathname.new('gemhome')

  @ignore_modules = []

  @options = {
    lzma_mode: true,
    extra_dlls: [],
    files: [],
    run_script: true,
    add_all_core: false,
    output_override: nil,
    load_autoload: true,
    chdir_first: false,
    force_windows: false,
    force_console: false,
    icon_filename: nil,
    gemfile: nil,
    inno_script: nil,
    quiet: false,
    verbose: false,
    autodll: true,
    show_warnings: true,
    debug: false,
    debug_extract: false,
    arg: [],
    enc: true,
    allow_self: false,
    gem: []
  }

  @options.each_key { |opt| eval("def self.#{opt}; @options[:#{opt}]; end") }

  class << self
    attr_reader :lzmapath, :ediconpath, :stubimage, :stubwimage
  end

  # Returns a binary blob store embedded in the current Ruby script.
  def self.next_embedded_image
    DATA.read(DATA.readline.to_i).unpack1('m')
  end

  def self.save_environment
    @load_path_before = $LOAD_PATH.dup
    @pwd_before = Dir.pwd
    @env_before = {}
    ENV.each { |key, value| @env_before[key] = value }
  end

  def self.restore_environment
    @env_before.each { |key, value| ENV[key] = value }
    ENV.each_key { |key| ENV.delete(key) unless @env_before.key?(key) }
    Dir.chdir @pwd_before
  end

  def self.find_stubs
    if defined?(DATA)
      @stubimage = next_embedded_image
      @stubwimage = next_embedded_image
      lzmaimage = next_embedded_image
      @lzmapath = Host.tempdir / 'lzma.exe'
      File.open(@lzmapath, 'wb') { |file| file << lzmaimage }
      ediconimage = next_embedded_image
      @ediconpath = Host.tempdir / 'edicon.exe'
      File.open(@ediconpath, 'wb') { |file| file << ediconimage }
    else
      aibikapath = Pathname(File.dirname(__FILE__))
      @stubimage = File.open(aibikapath / '../share/aibika/stub.exe', 'rb', &:read)
      @stubwimage = File.open(aibikapath / '../share/aibika/stubw.exe', 'rb', &:read)
      @lzmapath = (aibikapath / '../share/aibika/lzma.exe').expand
      @ediconpath = (aibikapath / '../share/aibika/edicon.exe').expand
    end
  end

  def self.init(argv)
    save_environment
    parseargs(argv)
    find_stubs
    @ignore_modules.push(*ObjectSpace.each_object(Module).to_a)
  end

  # Force loading autoloaded constants. Searches through all modules
  # (and hence classes), and checks their constants for autoloaded
  # ones, then attempts to load them.
  def self.attempt_load_autoload
    modules_checked = {}
    @ignore_modules.each { |m| modules_checked[m] = true }
    loop do
      modules_to_check = []
      ObjectSpace.each_object(Module) do |mod|
        modules_to_check << mod unless modules_checked.include?(mod)
      end
      break if modules_to_check.empty?

      modules_to_check.each do |mod|
        modules_checked[mod] = true
        mod.constants.each do |const|
          # Module::Config causes warning on Ruby 1.9.3 - prevent autoloading
          next if mod.is_a?(Module) && const == :Config

          next unless mod.autoload?(const)

          Aibika.msg "Attempting to trigger autoload of #{mod}::#{const}"
          begin
            mod.const_get(const)
          rescue NameError
            Aibika.warn "#{mod}::#{const} was defined autoloadable, but caused NameError"
          rescue LoadError
            Aibika.warn "#{mod}::#{const} was not loadable"
          end
        end
      end
    end
  end

  # Guess the load path (from 'paths') that was used to load
  # 'path'. This is primarily relevant on Ruby 1.8 which stores
  # "unqualified" paths in $LOADED_FEATURES.
  def self.find_load_path(loadpaths, feature)
    if feature.absolute?
      # Choose those loadpaths which contain the feature
      candidate_loadpaths = loadpaths.select { |loadpath| feature.subpath?(loadpath.expand) }
      # Guess the require'd feature
      feature_pairs = candidate_loadpaths.map { |loadpath| [loadpath, feature.relative_path_from(loadpath.expand)] }
      # Select the shortest possible require-path (longest load-path)
      if feature_pairs.empty?
        nil
      else
        feature_pairs.min_by { |_loadpath, feature| feature.path.size }[0]
      end
    else
      # Select the loadpaths that contain 'feature' and select the shortest
      candidates = loadpaths.select { |loadpath| feature.expand(loadpath).exist? }
      candidates.max_by { |loadpath| loadpath.path.size }
    end
  end

  # Find the root of all files specified on the command line and use
  # it as the "src" of the output.
  def self.find_src_root(files)
    src_files = files.map(&:expand)
    src_prefix = src_files.inject(src_files.first.dirname) do |srcroot, path|
      unless path.subpath?(Host.exec_prefix)
        loop do
          relpath = path.relative_path_from(srcroot)
          Aibika.fatal_error 'No common directory contains all specified files' if relpath.absolute?
          break unless relpath.to_s =~ %r{^\.\./}

          srcroot = srcroot.dirname
          if srcroot == srcroot.dirname
            Aibika.fatal_error "Endless loop detected in find_src_root method. Reducing srcroot --> #{srcroot.dirname}"
          end
        end
      end
      srcroot
    end
    src_files = src_files.map do |file|
      if file.subpath?(src_prefix)
        file.relative_path_from(src_prefix)
      else
        file
      end
    end
    [src_prefix, src_files]
  end

  # Searches for features that are loaded from gems, then produces a
  # list of files included in those gems' manifests. Also returns a
  # list of original features that are caused gems to be
  # included. Ruby 1.8 provides Gem.loaded_specs to detect gems, but
  # this is empty with Ruby 1.9. So instead, we look for any loaded
  # file from a gem path.
  def self.find_gem_files(features)
    features_from_gems = []
    gems = {}

    # If a Bundler Gemfile was provided, add all gems it specifies
    if Aibika.gemfile
      Aibika.msg 'Scanning Gemfile'
      # Load Rubygems and Bundler so we can scan the Gemfile
      %w[rubygems bundler].each do |lib|
        require lib
      rescue LoadError
        Aibika.fatal_error "Couldn't scan Gemfile, unable to load #{lib}"
      end

      ENV['BUNDLE_GEMFILE'] = Aibika.gemfile
      Bundler.load.specs.each do |spec|
        Aibika.verbose_msg "From Gemfile, adding gem #{spec.full_name}"
        gems[spec.name] ||= spec unless fence_self?(spec.name)
      end

      unless gems.any? { |name, _spec| name == 'bundler' }
        # Bundler itself wasn't added for some reason, let's put it in directly
        Aibika.verbose_msg 'From Gemfile, forcing inclusion of bundler gem itself'
        bundler_spec = Gem.loaded_specs['bundler']
        bundler_spec or Aibika.fatal_error 'Unable to locate bundler gem'
        gems['bundler'] ||= spec
      end
    end

    if defined?(Gem)
      # Include Gems that are loaded
      Gem.loaded_specs.each { |gemname, spec| gems[gemname] ||= spec unless fence_self?(gemname) }
      # Fall back to gem detection (loaded_specs are not population on
      # all Ruby versions)
      features.each do |feature|
        # Detect load path unless absolute
        unless feature.absolute?
          feature = find_load_path(Pathname($LOAD_PATH), feature)
          next if feature.nil? # Could be enumerator.so
        end
        # Skip if found in known Gem dir
        if gems.find { |_gem, spec| feature.subpath?(spec.gem_dir) }
          features_from_gems << feature
          next
        end
        gempaths = Pathname(Gem.path)
        gempaths.each do |gempath|
          geminstallpath = Pathname(gempath) / 'gems'
          next unless feature.subpath?(geminstallpath)

          gemlocalpath = feature.relative_path_from(geminstallpath)
          fullgemname = gemlocalpath.path.split('/').first
          gemspecpath = gempath / 'specifications' / "#{fullgemname}.gemspec"
          if (spec = Gem::Specification.load(gemspecpath))
            gems[spec.name] ||= spec
            features_from_gems << feature
          else
            Aibika.warn "Failed to load gemspec for '#{fullgemname}'"
          end
        end
      end

      gem_files = []

      gems.each do |gemname, spec|
        next if fence_self?(gemname)

        if File.exist?(spec.spec_file)
          @gemspecs << Pathname(spec.spec_file)
        else
          spec_name = File.basename(spec.spec_file)
          spec_path = File.dirname(spec.spec_file)
          default_spec_file = "#{spec_path}/default/#{spec_name}"
          if File.exist?(default_spec_file)
            @gemspecs << Pathname(default_spec_file)
            Aibika.msg "Using default specification #{default_spec_file} for gem #{spec.full_name}"
          end
        end

        # Determine which set of files to include for this particular gem
        include = %i[loaded files]
        Aibika.gem.each do |negate, option, list|
          next unless list.nil? || list.include?(spec.name)

          case option
          when :minimal
            include = [:loaded]
          when :guess
            include = %i[loaded files]
          when :all
            include = %i[scripts files]
          when :full
            include = %i[scripts files extras]
          when :spec
            include = [:spec]
          when :scripts
            if negate
              include.delete(:scripts)
            else
              include.push(:scripts)
            end
          when :files
            if negate
              include.delete(:files)
            else
              include.push(:files)
            end
          when :extras
            if negate
              include.delete(:extras)
            else
              include.push(:extras)
            end
          end
        end

        Aibika.msg "Detected gem #{spec.full_name} (#{include.join(', ')})"

        gem_root = Pathname(spec.gem_dir)
        gem_extension = (gem_root / '..' / '..' / 'extensions').expand
        build_complete = if gem_extension.exist?
                           gem_extension.find_all_files(/gem.build_complete/).select do |p|
                             p.dirname.basename.to_s == spec.full_name
                           end
                         end
        gem_root_files = nil
        files = []

        unless gem_root.directory?
          Aibika.warn "Gem #{spec.full_name} root folder was not found, skipping"
          next
        end

        # Find the selected files
        include.each do |set|
          case set
          when :spec
            files << Pathname(spec.files)
          when :loaded
            files << features_from_gems.select { |feature| feature.subpath?(gem_root) }
          when :files
            gem_root_files ||= gem_root.find_all_files(//)
            files << gem_root_files.reject { |path| path.relative_path_from(gem_root) =~ GEM_NON_FILE_RE }
            files << build_complete if build_complete
          when :extras
            gem_root_files ||= gem_root.find_all_files(//)
            files << gem_root_files.select { |path| path.relative_path_from(gem_root) =~ GEM_EXTRA_RE }
          when :scripts
            gem_root_files ||= gem_root.find_all_files(//)
            files << gem_root_files.select { |path| path.relative_path_from(gem_root) =~ GEM_SCRIPT_RE }
          end
        end

        files.flatten!
        actual_files = files.select(&:file?)

        (files - actual_files).each do |missing_file|
          Aibika.warn "#{missing_file} was not found"
        end

        total_size = actual_files.inject(0) { |size, path| size + path.size }
        Aibika.msg "\t#{actual_files.size} files, #{total_size} bytes"

        gem_files += actual_files
      end
      gem_files = sort_uniq(gem_files)
    else
      gem_files = []
    end
    features_from_gems -= gem_files
    [gem_files, features_from_gems]
  end

  def self.build_exe
    all_load_paths = $LOAD_PATH.map { |loadpath| Pathname(loadpath).expand }
    @added_load_paths = ($LOAD_PATH - @load_path_before).map { |loadpath| Pathname(loadpath).expand }
    working_directory = Pathname.pwd.expand

    restore_environment

    # If the script was run, then detect the features it used
    if Aibika.run_script && Aibika.load_autoload
      # Attempt to autoload libraries before doing anything else.
      attempt_load_autoload
    end

    # Reject own aibika itself, store the currently loaded files (before we require rbconfig for
    # our own use).
    features = $LOADED_FEATURES.reject { |feature| fence_self_dir?(feature) }
    features.map! { |feature| Pathname(feature) }

    # Since https://github.com/rubygems/rubygems/commit/cad4cf16cf8fcc637d9da643ef97cf0be2ed63cb
    # rubygems/core_ext/kernel_require.rb is evaled and thus missing in $LOADED_FEATURES,
    # so we can't find it and need to add it manually
    features.push(Pathname('rubygems/core_ext/kernel_require.rb'))

    # Find gemspecs to include
    if defined?(Gem)
      loaded_specs = Gem.loaded_specs.reject { |name, _info| fence_self?(name) }
      @gemspecs = loaded_specs.map { |_name, info| Pathname(info.loaded_from) }
    else
      @gemspecs = []
    end

    require 'rbconfig'
    instsitelibdir = Host.sitelibdir.relative_path_from(Host.exec_prefix)

    load_path = []
    src_load_path = []

    # Find gems files and remove them from features
    gem_files, features_from_gems = find_gem_files(features)
    features -= features_from_gems

    # Find the source root and adjust paths
    src_prefix, = find_src_root(Aibika.files)
    # Include encoding support files
    if Aibika.enc
      all_load_paths.each do |path|
        next unless path.subpath?(Host.exec_prefix)

        encpath = path / 'enc'
        next unless encpath.exist?

        encfiles = encpath.find_all_files(/\.so$/)
        size = encfiles.inject(0) { |sum, pn| sum + pn.size }
        Aibika.msg "Including #{encfiles.size} encoding support files (#{size} bytes, use --no-enc to exclude)"
        features.push(*encfiles)
      end
    else
      Aibika.msg 'Not including encoding support files'
    end

    # Find features and decide where to put them in the temporary
    # directory layout.
    libs = []
    features.each do |feature|
      path = find_load_path(all_load_paths, feature)
      if path.nil? || path.expand == Pathname.pwd
        Aibika.files << feature
      else
        feature = feature.relative_path_from(path.expand) if feature.absolute?
        fullpath = feature.expand(path)

        if fullpath.subpath?(Host.exec_prefix)
          # Features found in the Ruby installation are put in the
          # temporary Ruby installation.
          libs << [fullpath, fullpath.relative_path_from(Host.exec_prefix)]
        elsif defined?(Gem) && ((gemhome = Gem.path.find { |pth| fullpath.subpath?(pth) }))
          # Features found in any other Gem path (e.g. ~/.gems) is put
          # in a special 'gemhome' folder.
          targetpath = GEMHOMEDIR / fullpath.relative_path_from(Pathname(gemhome))
          libs << [fullpath, targetpath]
        elsif fullpath.subpath?(src_prefix) || path == working_directory
          # Any feature found inside the src_prefix automatically gets
          # added as a source file (to go in 'src').
          Aibika.files << fullpath
          # Add the load path unless it was added by the script while
          # running (or we assume that the script can also set it up
          # correctly when running from the resulting executable).
          src_load_path << path unless @added_load_paths.include?(path)
        elsif @added_load_paths.include?(path)
          # Any feature that exist in a load path added by the script
          # itself is added as a file to go into the 'src' (src_prefix
          # will be adjusted below to point to the common parent).
          Aibika.files << fullpath
        else
          # All other feature that can not be resolved go in the the
          # Ruby sitelibdir. This is automatically in the load path
          # when Ruby starts.
          libs << [fullpath, instsitelibdir / feature]
        end
      end
    end

    # Recompute the src_prefix. Files may have been added implicitly
    # while scanning through features.
    src_prefix, src_files = find_src_root(Aibika.files)
    Aibika.files.replace(src_files)

    # Add the load path that are required with the correct path after
    # src_prefix was adjusted.
    load_path += src_load_path.map { |loadpath| TEMPDIR_ROOT / SRCDIR / loadpath.relative_path_from(src_prefix) }

    # Decide where to put gem files, either the system gem folder, or
    # GEMHOME.
    gem_files.each do |gemfile|
      if gemfile.subpath?(Host.exec_prefix)
        libs << [gemfile, gemfile.relative_path_from(Host.exec_prefix)]
      elsif defined?(Gem) && ((gemhome = Gem.path.find { |pth| gemfile.subpath?(pth) }))
        targetpath = GEMHOMEDIR / gemfile.relative_path_from(Pathname(gemhome))
        libs << [gemfile, targetpath]
      else
        Aibika.msg "Processing #{gemfile}"
        Aibika.msg "Host.exec_prefix #{Host.exec_prefix}"
        Aibika.msg "Gem: #{Gem}" if defined?(Gem)
        Aibika.fatal_error "Don't know where to put gem file #{gemfile}"
      end
    end

    # If requested, add all ruby standard libraries
    if Aibika.add_all_core
      Aibika.msg 'Will include all ruby core libraries'
      @load_path_before.each do |lp|
        path = Pathname.new(lp)
        next unless path.to_posix =~
                    %r{/(ruby/(?:site_ruby/|vendor_ruby/)?[0-9.]+)/?$}i

        subdir = ::Regexp.last_match(1)
        Dir["#{lp}/**/*"].each do |f|
          fpath = Pathname.new(f)
          next if fpath.directory?

          tgt = "lib/#{subdir}/#{fpath.relative_path_from(path).to_posix}"
          libs << [f, tgt]
        end
      end
    end

    # Detect additional DLLs
    dlls = Aibika.autodll ? LibraryDetector.detect_dlls : []

    # Detect external manifests
    manifests = Host.exec_prefix.find_all_files(/\.manifest$/)

    executable = nil
    if Aibika.output_override
      executable = Aibika.output_override
    else
      executable = Aibika.files.first.basename.ext('.exe')
      executable.append_to_filename!('-debug') if Aibika.debug
    end

    windowed = (Aibika.files.first.ext?('.rbw') || Aibika.force_windows) && !Aibika.force_console

    Aibika.msg "Building #{executable}"
    target_script = nil
    AibikaBuilder.new(executable, windowed) do |sb|
      # Add explicitly mentioned files
      Aibika.msg 'Adding user-supplied source files'
      Aibika.files.each do |file|
        file = src_prefix / file
        target = if file.subpath?(Host.exec_prefix)
                   file.relative_path_from(Host.exec_prefix)
                 elsif file.subpath?(src_prefix)
                   SRCDIR / file.relative_path_from(src_prefix)
                 else
                   SRCDIR / file.basename
                 end

        target_script ||= target

        if file.directory?
          sb.ensuremkdir(target)
        else
          begin
            sb.createfile(file, target)
          rescue Errno::ENOENT
            raise unless file =~ IGNORE_MODULE_NAMES
          end
        end
      end

      # Add the ruby executable and DLL
      rubyexe = if windowed
                  Host.rubyw_exe
                else
                  Host.ruby_exe
                end
      Aibika.msg "Adding ruby executable #{rubyexe}"
      sb.createfile(Host.bindir / rubyexe, BINDIR / rubyexe)
      sb.createfile(Host.bindir / Host.libruby_so, BINDIR / Host.libruby_so) if Host.libruby_so

      # Add detected DLLs
      dlls.each do |dll|
        Aibika.msg "Adding detected DLL #{dll}"
        target = if dll.subpath?(Host.exec_prefix)
                   dll.relative_path_from(Host.exec_prefix)
                 else
                   BINDIR / File.basename(dll)
                 end
        sb.createfile(dll, target)
      end

      # Add external manifest files
      manifests.each do |manifest|
        Aibika.msg "Adding external manifest #{manifest}"
        target = manifest.relative_path_from(Host.exec_prefix)
        sb.createfile(manifest, target)
      end

      # Add extra DLLs specified on the command line
      Aibika.extra_dlls.each do |dll|
        Aibika.msg "Adding supplied DLL #{dll}"
        sb.createfile(Host.bindir / dll, BINDIR / dll)
      end

      # Add gemspec files
      @gemspecs = sort_uniq(@gemspecs)
      @gemspecs.each do |gemspec|
        if gemspec.subpath?(Host.exec_prefix)
          path = gemspec.relative_path_from(Host.exec_prefix)
          sb.createfile(gemspec, path)
        elsif defined?(Gem) && ((gemhome = Pathname(Gem.path.find { |pth| gemspec.subpath?(pth) })))
          path = GEMHOMEDIR / gemspec.relative_path_from(gemhome)
          sb.createfile(gemspec, path)
        else
          Aibika.fatal_error "Gem spec #{gemspec} does not exist in the Ruby installation. Don't know where to put it."
        end
      end

      # Add loaded libraries (features, gems)
      Aibika.msg 'Adding library files'
      libs.each do |path, target|
        sb.createfile(path, target)
      end

      # Set environment variable
      sb.setenv('RUBYOPT', ENV['RUBYOPT'] || '')
      sb.setenv('RUBYLIB', load_path.map(&:to_native).uniq.join(';'))

      sb.setenv('GEM_PATH', (TEMPDIR_ROOT / GEMHOMEDIR).to_native)

      # Add the opcode to launch the script
      extra_arg = Aibika.arg.map { |arg| " \"#{arg.gsub('"', '\"')}\"" }.join
      installed_ruby_exe = TEMPDIR_ROOT / BINDIR / rubyexe
      launch_script = (TEMPDIR_ROOT / target_script).to_native
      sb.postcreateprocess(installed_ruby_exe,
                           "#{rubyexe} \"#{launch_script}\"#{extra_arg}")
    end

    return if Aibika.inno_script

    Aibika.msg "Finished building #{executable} (#{File.size(executable)} bytes)"
  end
end
