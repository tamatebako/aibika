# frozen_string_literal: true

module Aibika
  # Utility class that produces the actual executable. Opcodes
  # (createfile, mkdir etc) are added by invoking methods on an
  # instance of AibikaBuilder.
  class AibikaBuilder
    Signature = [0x41, 0xb6, 0xba, 0x4e].freeze
    OP_END = 0
    OP_CREATE_DIRECTORY = 1
    OP_CREATE_FILE = 2
    OP_CREATE_PROCESS = 3
    OP_DECOMPRESS_LZMA = 4
    OP_SETENV = 5
    OP_POST_CREATE_PROCESS = 6
    OP_ENABLE_DEBUG_MODE = 7
    OP_CREATE_INST_DIRECTORY = 8

    def initialize(path, windowed)
      @paths = {}
      @files = {}
      File.open(path, 'wb') do |aibikafile|
        image = if windowed
                  Aibika.stubwimage
                else
                  Aibika.stubimage
                end

        Aibika.fatal_error 'Stub image not available' unless image
        aibikafile.write(image)
      end

      system Aibika.ediconpath, path, Aibika.icon_filename if Aibika.icon_filename

      opcode_offset = File.size(path)

      File.open(path, 'ab') do |aibikafile|
        tmpinpath = 'tmpin'

        @of = if Aibika.lzma_mode
                File.open(tmpinpath, 'wb')
              else
                aibikafile
              end

        if Aibika.debug
          Aibika.msg('Enabling debug mode in executable')
          aibikafile.write([OP_ENABLE_DEBUG_MODE].pack('V'))
        end

        createinstdir Aibika.debug_extract, !Aibika.debug_extract, Aibika.chdir_first

        yield(self)

        @of.close if Aibika.lzma_mode

        if Aibika.lzma_mode && !Aibika.inno_script
          tmpoutpath = 'tmpout'
          begin
            data_size = File.size(tmpinpath)
            Aibika.msg "Compressing #{data_size} bytes"
            system(Aibika.lzmapath, 'e', tmpinpath, tmpoutpath) or raise
            compressed_data_size = File.size?(tmpoutpath)
            aibikafile.write([OP_DECOMPRESS_LZMA, compressed_data_size].pack('VV'))
            IO.copy_stream(tmpoutpath, aibikafile)
          ensure
            File.unlink(@of.path) if File.exist?(@of.path)
            File.unlink(tmpoutpath) if File.exist?(tmpoutpath)
          end
        end

        aibikafile.write([OP_END].pack('V'))
        aibikafile.write([opcode_offset].pack('V')) # Pointer to start of opcodes
        aibikafile.write(Signature.pack('C*'))
      end

      return unless Aibika.inno_script

      begin
        iss = "#{File.read(Aibika.inno_script)}\n\n"

        iss << "[Dirs]\n"
        @paths.each_key do |p|
          iss << "Name: \"{app}/#{p}\"\n"
        end
        iss << "\n"

        iss << "[Files]\n"
        path_escaped = path.to_s.gsub('"', '""')
        iss << "Source: \"#{path_escaped}\"; DestDir: \"{app}\"\n"
        @files.each do |tgt, src|
          src_escaped = src.to_s.gsub('"', '""')
          target_dir_escaped = Pathname.new(tgt).dirname.to_s.gsub('"', '""')
          unless src_escaped =~ IGNORE_MODULE_NAMES
            iss << "Source: \"#{src_escaped}\"; DestDir: \"{app}/#{target_dir_escaped}\"\n"
          end
        end
        iss << "\n"

        Aibika.verbose_msg "### INNOSETUP SCRIPT ###\n\n#{iss}\n\n"

        f = File.open('aibikatemp.iss', 'w')
        f.write(iss)
        f.close

        iscc_cmd = ['iscc']
        iscc_cmd << '/Q' unless Aibika.verbose
        iscc_cmd << 'aibikatemp.iss'
        Aibika.msg 'Running InnoSetup compiler ISCC'
        result = system(*iscc_cmd)
        unless result
          case $CHILD_STATUS
          when 0 then raise 'ISCC reported success, but system reported error?'
          when 1 then raise 'ISCC reports invalid command line parameters'
          when 2 then raise 'ISCC reports that compilation failed'
          else raise 'ISCC failed to run. Is the InnoSetup directory in your PATH?'
          end
        end
      rescue Exception => e
        Aibika.fatal_error("InnoSetup installer creation failed: #{e.message}")
      ensure
        File.unlink('aibikatemp.iss') if File.exist?('aibikatemp.iss')
        File.unlink(path) if File.exist?(path)
      end
    end

    def mkdir(path)
      return if @paths[path.path.downcase]

      @paths[path.path.downcase] = true
      Aibika.verbose_msg "m #{showtempdir path}"
      return if Aibika.inno_script # The directory will be created by InnoSetup with a [Dirs] statement

      @of << [OP_CREATE_DIRECTORY, path.to_native].pack('VZ*')
    end

    def ensuremkdir(tgt)
      tgt = Aibika.Pathname(tgt)
      return if tgt.path == '.'

      return if @paths[tgt.to_posix.downcase]

      ensuremkdir(tgt.dirname)
      mkdir(tgt)
    end

    def createinstdir(next_to_exe = false, delete_after = false, chdir_before = false)
      return if Aibika.inno_script # Creation of installation directory will be handled by InnoSetup

      @of << [OP_CREATE_INST_DIRECTORY, next_to_exe ? 1 : 0, delete_after ? 1 : 0, chdir_before ? 1 : 0].pack('VVVV')
    end

    def createfile(src, tgt)
      return if @files[tgt]

      @files[tgt] = src
      src = Aibika.Pathname(src)
      tgt = Aibika.Pathname(tgt)
      ensuremkdir(tgt.dirname)
      str = File.binread(src)
      Aibika.verbose_msg "a #{showtempdir tgt}"
      return if Aibika.inno_script # InnoSetup will install the file with a [Files] statement

      @of << [OP_CREATE_FILE, tgt.to_native, str.size].pack('VZ*V')
      @of << str
    end

    def createprocess(image, cmdline)
      Aibika.verbose_msg "l #{showtempdir image} #{showtempdir cmdline}"
      @of << [OP_CREATE_PROCESS, image.to_native, cmdline].pack('VZ*Z*')
    end

    def postcreateprocess(image, cmdline)
      Aibika.verbose_msg "p #{showtempdir image} #{showtempdir cmdline}"
      @of << [OP_POST_CREATE_PROCESS, image.to_native, cmdline].pack('VZ*Z*')
    end

    def setenv(name, value)
      Aibika.verbose_msg "e #{name} #{showtempdir value}"
      @of << [OP_SETENV, name, value].pack('VZ*Z*')
    end

    def close
      @of.close
    end

    def showtempdir(tdir)
      tdir.to_s.gsub(TEMPDIR_ROOT, '<tempdir>')
    end
  end
end
