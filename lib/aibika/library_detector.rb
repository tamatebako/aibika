# frozen_string_literal: true

module Aibika
  module LibraryDetector
    def self.init_fiddle
      require 'fiddle'
      require 'fiddle/types'
      module_eval do
        extend Fiddle::Importer
        dlload 'psapi.dll'
        include Fiddle::Win32Types
        extern 'BOOL EnumProcessModules(HANDLE, HMODULE*, DWORD, DWORD*)'
        extend Fiddle::Importer
        dlload 'kernel32.dll'
        include Fiddle::Win32Types

        # https://docs.microsoft.com/en-us/windows/win32/winprog/windows-data-types
        # typedef PVOID HANDLE
        # typedef HINSTANCE HMODULE;

        typealias 'HMODULE', 'voidp'
        typealias 'HANDLE', 'voidp'
        typealias 'LPWSTR', 'char*'

        extern 'DWORD GetModuleFileNameW(HMODULE, LPWSTR, DWORD)'
        extern 'HANDLE GetCurrentProcess(void)'
        extern 'DWORD GetLastError(void)'
      end
    end

    def self.loaded_dlls
      require 'fiddle'
      psapi = Fiddle.dlopen('psapi')
      enumprocessmodules = Fiddle::Function.new(
        psapi['EnumProcessModules'],
        [Fiddle::TYPE_UINTPTR_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG
      )
      kernel32 = Fiddle.dlopen('kernel32')
      getcurrentprocess = Fiddle::Function.new(kernel32['GetCurrentProcess'], [], Fiddle::TYPE_LONG)
      getmodulefilename = Fiddle::Function.new(
        kernel32['GetModuleFileNameW'],
        [Fiddle::TYPE_UINTPTR_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG
      )
      getlasterror = Fiddle::Function.new(kernel32['GetLastError'], [], Fiddle::TYPE_LONG)

      # Different packing/unpacking for 64/32 bits systems
      if Fiddle::SIZEOF_VOIDP == 8
        f_single = 'Q'
        f_array  = 'Q*'
      else
        f_single = 'I'
        f_array = 'I*'
      end

      bytes_needed = Fiddle::SIZEOF_VOIDP * 32
      module_handle_buffer = nil
      process_handle = getcurrentprocess.call
      loop do
        module_handle_buffer = "\x00" * bytes_needed
        bytes_needed_buffer = [0].pack(f_single)
        enumprocessmodules.call(process_handle, module_handle_buffer, module_handle_buffer.size,
                                bytes_needed_buffer)
        bytes_needed = bytes_needed_buffer.unpack1(f_single)
        break if bytes_needed <= module_handle_buffer.size
      end

      handles = module_handle_buffer.unpack(f_array)
      handles.select(&:positive?).map do |handle|
        str = "\x00\x00" * 256
        modulefilename_length = getmodulefilename.call(handle, str, str.size)
        unless modulefilename_length.positive?
          errorcode = getlasterror.call
          Aibika.fatal_error "LibraryDetector: GetModuleFileNameW failed with error code 0x#{errorcode.to_s(16)}"
        end
        modulefilename = str[0, modulefilename_length * 2].force_encoding('UTF-16LE').encode('UTF-8')
        Aibika.Pathname(modulefilename)
      end
    end

    def self.detect_dlls
      loaded = loaded_dlls
      exec_prefix = Host.exec_prefix
      loaded.select do |path|
        path.subpath?(exec_prefix) && path.basename.ext?('.dll') && path.basename != Host.libruby_so
      end
    end
  end
end
