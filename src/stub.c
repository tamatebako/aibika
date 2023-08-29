/*
  Single Executable Bundle Stub

  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <tchar.h>
#include <stdio.h>

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

#define OP_END 0
#define OP_CREATE_DIRECTORY 1
#define OP_CREATE_FILE 2
#define OP_CREATE_PROCESS 3
#define OP_DECOMPRESS_LZMA 4
#define OP_SETENV 5
#define OP_POST_CREATE_PROCRESS 6
#define OP_ENABLE_DEBUG_MODE 7
#define OP_CREATE_INST_DIRECTORY 8
#define OP_MAX 9

/** Manages digital signatures **/

// Some usefule references:
// https://en.wikipedia.org/wiki/Portable_Executable for explanation of these header fields
// https://stackoverflow.com/questions/84847/how-do-i-create-a-self-signed-certificate-for-code-signing-on-windows?rq=3
// Command to sign:
// signtool.exe sign /f selfsigncert.pfx /p password helloworld.exe

#define SECURITY_ENTRY(header) ((header)->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_SECURITY])

static LPBYTE ocraSignatureLocation(LPBYTE, DWORD);
static PIMAGE_NT_HEADERS retrieveNTHeader(LPBYTE ptr) ;
static BOOL isDigitallySigned(PIMAGE_NT_HEADERS ntHeaders);
/******************************/

BOOL ProcessImage(LPBYTE p, DWORD size);
BOOL ProcessOpcodes(LPBYTE* p);
void CreateAndWaitForProcess(LPTSTR ApplicationName, LPTSTR CommandLine);

BOOL OpEnd(LPBYTE* p);
BOOL OpCreateFile(LPBYTE* p);
BOOL OpCreateDirectory(LPBYTE* p);
BOOL OpCreateProcess(LPBYTE* p);
BOOL OpDecompressLzma(LPBYTE* p);
BOOL OpSetEnv(LPBYTE* p);
BOOL OpPostCreateProcess(LPBYTE* p);
BOOL OpEnableDebugMode(LPBYTE* p);
BOOL OpCreateInstDirectory(LPBYTE* p);

#if WITH_LZMA
#include <LzmaDec.h>
#endif

typedef BOOL (*POpcodeHandler)(LPBYTE*);

LPTSTR PostCreateProcess_ApplicationName = NULL;
LPTSTR PostCreateProcess_CommandLine = NULL;

DWORD ExitStatus = 0;
BOOL ExitCondition = FALSE;
BOOL DebugModeEnabled = FALSE;
BOOL DeleteInstDirEnabled = FALSE;
BOOL ChdirBeforeRunEnabled = TRUE;
TCHAR ImageFileName[MAX_PATH];

#if _CONSOLE
#define FATAL(...) { fprintf(stderr, "FATAL ERROR: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); }
#else
#define FATAL(...) { \
   TCHAR TextBuffer[1024]; \
   _sntprintf(TextBuffer, 1024, __VA_ARGS__); \
   MessageBox(NULL, TextBuffer, _T("AIBIKA"), MB_OK | MB_ICONWARNING); \
   }
#endif

#if _CONSOLE
#define DEBUG(...) { if (DebugModeEnabled) { fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } }
#else
#define DEBUG(...)
#endif

POpcodeHandler OpcodeHandlers[OP_MAX] =
{
   &OpEnd,
   &OpCreateDirectory,
   &OpCreateFile,
   &OpCreateProcess,
#if WITH_LZMA
   &OpDecompressLzma,
#else
   NULL,
#endif
   &OpSetEnv,
   &OpPostCreateProcess,
   &OpEnableDebugMode,
   &OpCreateInstDirectory,
};

TCHAR InstDir[MAX_PATH];

/** Decoder: Zero-terminated string */
LPTSTR GetString(LPBYTE* p)
{
   LPTSTR str = *(LPTSTR*)p;
   *p += lstrlen(str) + sizeof(TCHAR);
   return str;
}

/** Decoder: 32 bit unsigned integer */
DWORD GetInteger(LPBYTE* p)
{
   DWORD dw = *(DWORD*)*p;
   *p += 4;
   return dw;
}

/**
   Handler for console events.
*/
BOOL WINAPI ConsoleHandleRoutine(DWORD dwCtrlType)
{
   // Ignore all events. They will also be dispatched to the child procress (Ruby) which should
   // exit quickly, allowing us to clean up.
   return TRUE;
}

void FindExeDir(TCHAR* d)
{
   strncpy(d, ImageFileName, MAX_PATH);
   unsigned int i;
   for (i = strlen(d)-1; i >= 0; --i)
   {
      if (i == 0 || d[i] == '\\')
      {
         d[i] = 0;
         break;
      }
   }
}

BOOL DeleteRecursively(LPTSTR path)
{
   TCHAR findPath[MAX_PATH];
   DWORD pathLength;
   WIN32_FIND_DATA findData;
   HANDLE handle;
   BOOL AnyFailed = FALSE;

   lstrcpy(findPath, path);
   pathLength = lstrlen(findPath);
   if (pathLength > 1 && pathLength < MAX_PATH - 2) {
      if (path[pathLength-1] == '\\')
         lstrcat(findPath, "*");
      else {
         lstrcat(findPath, "\\*");
         ++pathLength;
      }
      handle = FindFirstFile(findPath, &findData);
      findPath[pathLength] = 0;
      if (handle != INVALID_HANDLE_VALUE) {
         do {
            if (pathLength + lstrlen(findData.cFileName) < MAX_PATH) {
               TCHAR subPath[MAX_PATH];
               lstrcpy(subPath, findPath);
               lstrcat(subPath, findData.cFileName);
               if ((lstrcmp(findData.cFileName, ".") != 0) && (lstrcmp(findData.cFileName, "..") != 0)) {
                  if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                     if (!DeleteRecursively(subPath))
                        AnyFailed = TRUE;
                  } else {
                     if (!DeleteFile(subPath)) {
                        MoveFileEx(subPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
                        AnyFailed = TRUE;
                     }
                  }
               }
            } else {
               AnyFailed = TRUE;
            }
         } while (FindNextFile(handle, &findData));
         FindClose(handle);
      }
   } else {
      AnyFailed = TRUE;
   }
   if (!RemoveDirectory(findPath)) {
      MoveFileEx(findPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
      AnyFailed = TRUE;
   }
   return AnyFailed;
}

void MarkForDeletion(LPTSTR path)
{
   TCHAR marker[MAX_PATH];
   lstrcpy(marker, path);
   lstrcat(marker, ".aibika-delete-me");
   HANDLE h = CreateFile(marker, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
   CloseHandle(h);
}

void DeleteRecursivelyNowOrLater(LPTSTR path)
{
   DEBUG("DeleteRecursivelyNowOrLater:  %s", path);
   if (!DeleteRecursively(path))
      MarkForDeletion(path);
}

void DeleteOldFiles()
{
   TCHAR path[MAX_PATH];
   DWORD len = GetTempPath(MAX_PATH, path);
   if (path[len-1] != '\\') {
      lstrcat(path, "\\");
      len += 1;
   }
   lstrcat(path, "*.aibika-delete-me");
   WIN32_FIND_DATA findData;
   HANDLE handle = FindFirstFile(path, &findData);
   path[len] = 0;
   if (handle == INVALID_HANDLE_VALUE)
      return;
   do {
      TCHAR aibikaPath[MAX_PATH];
      lstrcpy(aibikaPath, path);
      lstrcat(aibikaPath, findData.cFileName);
      DeleteFile(aibikaPath);
      DWORD len = lstrlen(aibikaPath);
      len -= lstrlen(".aibika-delete-me");
      aibikaPath[len] = 0;
      DeleteRecursivelyNowOrLater(aibikaPath);
   } while (FindNextFile(handle, &findData));
   FindClose(handle);
}

BOOL OpCreateInstDirectory(LPBYTE* p)
{
   DWORD DebugExtractMode = GetInteger(p);

   DeleteInstDirEnabled = GetInteger(p);
   ChdirBeforeRunEnabled = GetInteger(p);

   /* Create an installation directory that will hold the extracted files */
   TCHAR TempPath[MAX_PATH];
   if (DebugExtractMode)
   {
      // In debug extraction mode, create the temp directory next to the exe
      FindExeDir(TempPath);
      if (strlen(TempPath) == 0)
      {
         FATAL("Unable to find directory containing exe");
         return FALSE;
      }
   }
   else
   {
      GetTempPath(MAX_PATH, TempPath);
   }

   UINT tempResult = GetTempFileName(TempPath, _T("aibikastub"), 0, InstDir);
   if (tempResult == 0u)
   {
      FATAL("Failed to get temp file name.");
      return FALSE;
   }

   DEBUG("Creating installation directory: '%s'", InstDir);

   /* Attempt to delete the temp file created by GetTempFileName.
      Ignore errors, i.e. if it doesn't exist. */
   (void)DeleteFile(InstDir);

   if (!CreateDirectory(InstDir, NULL))
   {
      FATAL("Failed to create installation directory.");
      return FALSE;
   }
   return TRUE;
}

int CALLBACK _tWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPTSTR lpCmdLine, int nCmdShow)
{
   DeleteOldFiles();

   /* Find name of image */
   if (!GetModuleFileName(NULL, ImageFileName, MAX_PATH))
   {
      FATAL("Failed to get executable name (error %lu).", GetLastError());
      return -1;
   }


   /* By default, assume the installation directory is wherever the EXE is */
   FindExeDir(InstDir);

   /* Set up environment */
   SetEnvironmentVariable(_T("AIBIKA_EXECUTABLE"), ImageFileName);

   SetConsoleCtrlHandler(&ConsoleHandleRoutine, TRUE);

   /* Open the image (executable) */
   HANDLE hImage = CreateFile(ImageFileName, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
   if (hImage == INVALID_HANDLE_VALUE)
   {
      FATAL("Failed to open executable (%s)", ImageFileName);
      return -1;
   }

   /* Create a file mapping */
   DWORD FileSize = GetFileSize(hImage, NULL);
   HANDLE hMem = CreateFileMapping(hImage, NULL, PAGE_READONLY, 0, FileSize, NULL);
   if (hMem == INVALID_HANDLE_VALUE)
   {
      FATAL("Failed to create file mapping (error %lu)", GetLastError());
      CloseHandle(hImage);
      return -1;
   }

   /* Map the image into memory */
   LPBYTE lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
   if (lpv == NULL)
   {
      FATAL("Failed to map view of executable into memory (error %lu).", GetLastError());
   }
   else
   {
      if (!ProcessImage(lpv, FileSize))
      {
         ExitStatus = -1;
      }

      if (!UnmapViewOfFile(lpv))
      {
         FATAL("Failed to unmap view of executable.");
      }
   }

   if (!CloseHandle(hMem))
   {
      FATAL("Failed to close file mapping.");
   }

   if (!CloseHandle(hImage))
   {
      FATAL("Failed to close executable.");
   }

   if (ChdirBeforeRunEnabled)
   {
      DEBUG("Changing CWD to unpacked directory %s/src", InstDir);
      SetCurrentDirectory(InstDir);
      SetCurrentDirectory("./src");
   }

   if (PostCreateProcess_ApplicationName && PostCreateProcess_CommandLine)
   {
      DEBUG("**********");
      DEBUG("Starting app in: %s", InstDir);
      DEBUG("**********");
      CreateAndWaitForProcess(PostCreateProcess_ApplicationName, PostCreateProcess_CommandLine);
   }

   if (DeleteInstDirEnabled)
   {
      DEBUG("Deleting temporary installation directory %s", InstDir);
      TCHAR SystemDirectory[MAX_PATH];
      if (GetSystemDirectory(SystemDirectory, MAX_PATH) > 0)
         SetCurrentDirectory(SystemDirectory);
      else
         SetCurrentDirectory("C:\\");
      DeleteRecursivelyNowOrLater(InstDir);
   }

   ExitProcess(ExitStatus);

   /* Never gets here */
   return 0;
}

static PIMAGE_NT_HEADERS retrieveNTHeader(LPBYTE ptr)
{
   PIMAGE_NT_HEADERS ret = NULL;
   PIMAGE_DOS_HEADER dosHeader = (PIMAGE_DOS_HEADER)ptr;
   if (dosHeader->e_magic != 0x5a4d) {
      FATAL("Invalid DOS signature: %x, 0x5a4d expected", dosHeader->e_magic);
   }
   else {
      PIMAGE_NT_HEADERS ntHeader = (PIMAGE_NT_HEADERS)(ptr + dosHeader->e_lfanew);
      if (ntHeader->Signature != 0x4550) {
         FATAL("Invalid PE signature: %lx, 0x4550 expected", ntHeader->Signature);
      }
      else {
         ret = ntHeader;
      }
   }
  /* e_lfanew is an RVA (relative virtual address, i.e offset) to the NTHeader
   to get a usable pointer we add the RVA to the base address */
   return ret;
}

/* Check whether there's an embedded digital signature */
static BOOL isDigitallySigned(PIMAGE_NT_HEADERS ntHeader) {
  return SECURITY_ENTRY(ntHeader).Size != 0;
}

/* Find the location of ocra's signature
   NOTE: *not* the same as the digital signature from code signing
*/
static LPBYTE ocraSignatureLocation(LPBYTE ptr, DWORD size)
{
   LPBYTE ret = NULL;
   PIMAGE_NT_HEADERS ntHeader = retrieveNTHeader(ptr);
   if (ntHeader) {
      if (!isDigitallySigned(ntHeader)) {
         ret = ptr + size - 4;
      }
      else {
         DWORD offset = SECURITY_ENTRY(ntHeader).VirtualAddress - 1;
         LPBYTE searchPtr = ptr;

    /* There is unfortunately a 'buffer' of null bytes between the
       ocraSignature and the digital signature. This buffer appears to be random
       in size, so the only way we can account for it is to search backwards
       for the first non-null byte.
       NOTE: this means that the hard-coded Ocra signature cannot end with a null byte.
    */
         while(!searchPtr[offset])
            offset--;

    /* -3 cos we're already at the first byte and we need to go back 4 bytes */
         ret = searchPtr + offset - 3;
      }
   }
   return ret;
}

/**
   Process the image by checking the signature and locating the first
   opcode.
*/
BOOL ProcessImage(LPBYTE ptr, DWORD size)
{
   BOOL ret = FALSE;
   LPBYTE pSig = ocraSignatureLocation(ptr, size);
   if (pSig) {
      if (memcmp(pSig, Signature, 4) == 0)
      {
         DEBUG("Good signature found.");
         DWORD OpcodeOffset = *(DWORD*)(pSig - 4);
         LPBYTE pSeg = ptr + OpcodeOffset;
         ret = ProcessOpcodes(&pSeg);
      }
      else
      {
         FATAL("Bad signature in executable.");
      }
   }
   else {
         FATAL("No signature in executable.");
   }
   return ret;
}

/**
   Process the opcodes in memory.
*/
BOOL ProcessOpcodes(LPBYTE* p)
{
   while (!ExitCondition)
   {
      DWORD opcode = GetInteger(p);
      if (opcode < OP_MAX)
      {
         if (!OpcodeHandlers[opcode](p))
         {
            return FALSE;
         }
      }
      else
      {
         FATAL("Invalid opcode '%lu'.", opcode);
         return FALSE;
      }
   }
   return TRUE;
}

/**
   Expands a specially formatted string, replacing | with the
   temporary installation directory.
*/
void ExpandPath(LPTSTR* out, LPTSTR str)
{
   DWORD OutSize = lstrlen(str) + sizeof(TCHAR);
   LPTSTR a = str;
   while ((a = _tcschr(a, L'|')))
   {
      OutSize += lstrlen(InstDir) - sizeof(TCHAR);
      a++;
   }

   *out = LocalAlloc(LMEM_FIXED, OutSize);

   LPTSTR OutPtr = *out;
   while ((a = _tcschr(str, L'|')))
   {
      int l = a - str;
      if (l > 0)
      {
         memcpy(OutPtr, str, l);
         OutPtr += l;
         str += l;
      }
      str += sizeof(TCHAR);
      lstrcpy(OutPtr, InstDir);
      OutPtr += lstrlen(OutPtr);
   }
   lstrcpy(OutPtr, str);
}

/**
   Finds the start of the first argument after the current one. Handles quoted arguments.
*/
LPTSTR SkipArg(LPTSTR str)
{
   if (*str == '"')
   {
      str++;
      while (*str && *str != '"') { str++; }
      if (*str == '"') { str++; }
   }
   else
   {
      while (*str && *str != ' ') { str++; }
   }
   while (*str && *str != ' ') { str++; }
   return str;
}

/**
   Create a file (OP_CREATE_FILE opcode handler)
*/
BOOL OpCreateFile(LPBYTE* p)
{
   BOOL Result = TRUE;
   LPTSTR FileName = GetString(p);
   DWORD FileSize = GetInteger(p);
   LPBYTE Data = *p;
   *p += FileSize;

   TCHAR Fn[MAX_PATH];
   lstrcpy(Fn, InstDir);
   lstrcat(Fn, _T("\\"));
   lstrcat(Fn, FileName);

   DEBUG("CreateFile(%s, %lu)", Fn, FileSize);
   HANDLE hFile = CreateFile(Fn, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
   if (hFile != INVALID_HANDLE_VALUE)
   {
      DWORD BytesWritten;
      if (!WriteFile(hFile, Data, FileSize, &BytesWritten, NULL))
      {
         FATAL("Write failure (%lu)", GetLastError());
         Result = FALSE;
      }
      if (BytesWritten != FileSize)
      {
         FATAL("Write size failure");
         Result = FALSE;
      }
      CloseHandle(hFile);
   }
   else
   {
      FATAL("Failed to create file '%s'", Fn);
      Result = FALSE;
   }

   return Result;
}

/**
   Create a directory (OP_CREATE_DIRECTORY opcode handler)
*/
BOOL OpCreateDirectory(LPBYTE* p)
{
   LPTSTR DirectoryName = GetString(p);

   TCHAR DirName[MAX_PATH];
   lstrcpy(DirName, InstDir);
   lstrcat(DirName, _T("\\"));
   lstrcat(DirName, DirectoryName);

   DEBUG("CreateDirectory(%s)", DirName);

   if (!CreateDirectory(DirName, NULL))
   {
      if (GetLastError() == ERROR_ALREADY_EXISTS)
      {
         DEBUG("Directory already exists");
      }
      else
      {
         FATAL("Failed to create directory '%s'.", DirName);
         return FALSE;
      }
   }

   return TRUE;
}

void GetCreateProcessInfo(LPBYTE* p, LPTSTR* pApplicationName, LPTSTR* pCommandLine)
{
   LPTSTR ImageName = GetString(p);
   LPTSTR CmdLine = GetString(p);

   ExpandPath(pApplicationName, ImageName);

   LPTSTR ExpandedCommandLine;
   ExpandPath(&ExpandedCommandLine, CmdLine);

   LPTSTR MyCmdLine = GetCommandLine();
   LPTSTR MyArgs = SkipArg(MyCmdLine);

   *pCommandLine = LocalAlloc(LMEM_FIXED, lstrlen(ExpandedCommandLine) + sizeof(TCHAR) + lstrlen(MyArgs) + sizeof(TCHAR));
   lstrcpy(*pCommandLine, ExpandedCommandLine);
   lstrcat(*pCommandLine, _T(" "));
   lstrcat(*pCommandLine, MyArgs);

   LocalFree(ExpandedCommandLine);
}

/**
   Create a new process and wait for it to complete (OP_CREATE_PROCESS
   opcode handler)
*/
BOOL OpCreateProcess(LPBYTE* p)
{
   LPTSTR ApplicationName;
   LPTSTR CommandLine;
   GetCreateProcessInfo(p, &ApplicationName, &CommandLine);
   CreateAndWaitForProcess(ApplicationName, CommandLine);
   LocalFree(ApplicationName);
   LocalFree(CommandLine);
   return TRUE;
}

void CreateAndWaitForProcess(LPTSTR ApplicationName, LPTSTR CommandLine)
{
   PROCESS_INFORMATION ProcessInformation;
   STARTUPINFO StartupInfo;
   ZeroMemory(&StartupInfo, sizeof(StartupInfo));
   StartupInfo.cb = sizeof(StartupInfo);
   BOOL r = CreateProcess(ApplicationName, CommandLine, NULL, NULL,
                          TRUE, 0, NULL, NULL, &StartupInfo, &ProcessInformation);

   if (!r)
   {
      FATAL("Failed to create process (%s): %lu", ApplicationName, GetLastError());
      return;
   }

   WaitForSingleObject(ProcessInformation.hProcess, INFINITE);

   if (!GetExitCodeProcess(ProcessInformation.hProcess, &ExitStatus))
   {
      FATAL("Failed to get exit status (error %lu).", GetLastError());
   }

   CloseHandle(ProcessInformation.hProcess);
   CloseHandle(ProcessInformation.hThread);
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL OpPostCreateProcess(LPBYTE* p)
{
   DEBUG("PostCreateProcess");
   if (PostCreateProcess_ApplicationName || PostCreateProcess_CommandLine)
   {
      return FALSE;
   }
   else
   {
      GetCreateProcessInfo(p, &PostCreateProcess_ApplicationName, &PostCreateProcess_CommandLine);
      return TRUE;
   }
}

BOOL OpEnableDebugMode(LPBYTE* p)
{
   DebugModeEnabled = TRUE;
   DEBUG("Aibika stub running in debug mode");
   return TRUE;
}

#if WITH_LZMA
void* SzAlloc(void* p, size_t size) { p = p; return LocalAlloc(LMEM_FIXED, size); }
void SzFree(void* p, void* address) { p = p; LocalFree(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

#define LZMA_UNPACKSIZE_SIZE 8
#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)

BOOL OpDecompressLzma(LPBYTE* p)
{
   BOOL Success = TRUE;

   DWORD CompressedSize = GetInteger(p);
   DEBUG("LzmaDecode(%ld)", CompressedSize);

   Byte* src = (Byte*)*p;
   *p += CompressedSize;

   UInt64 unpackSize = 0;
   int i;
   for (i = 0; i < 8; i++)
   {
      unpackSize += (UInt64)src[LZMA_PROPS_SIZE + i] << (i * 8);
   }

   Byte* DecompressedData = LocalAlloc(LMEM_FIXED, unpackSize);

   SizeT lzmaDecompressedSize = unpackSize;
   SizeT inSizePure = CompressedSize - LZMA_HEADER_SIZE;
   ELzmaStatus status;
   SRes res = LzmaDecode(DecompressedData, &lzmaDecompressedSize, src + LZMA_HEADER_SIZE, &inSizePure,
                         src, LZMA_PROPS_SIZE, LZMA_FINISH_ANY, &status, &alloc);
   if (res != SZ_OK)
   {
      FATAL("LZMA decompression failed.");
      Success = FALSE;
   }
   else
   {
      LPBYTE decPtr = DecompressedData;
      if (!ProcessOpcodes(&decPtr))
      {
         Success = FALSE;
      }
   }

   LocalFree(DecompressedData);
   return Success;
}
#endif

BOOL OpEnd(LPBYTE* p)
{
   ExitCondition = TRUE;
   return TRUE;
}

BOOL OpSetEnv(LPBYTE* p)
{
   LPTSTR Name = GetString(p);
   LPTSTR Value = GetString(p);
   LPTSTR ExpandedValue;
   ExpandPath(&ExpandedValue, Value);
   DEBUG("SetEnv(%s, %s)", Name, ExpandedValue);

   BOOL Result = FALSE;
   if (!SetEnvironmentVariable(Name, ExpandedValue))
   {
      FATAL("Failed to set environment variable (error %lu).", GetLastError());
      Result = FALSE;
   }
   else
   {
      Result = TRUE;
   }
   LocalFree(ExpandedValue);
   return Result;
}
