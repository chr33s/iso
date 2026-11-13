// iso-cu-mcp: the computer-use MCP server an agent runs in a Linux guest with a display
// (docs/design/linux-desktop-virtio-gpu.md §8), built with the Static Linux SDK (scripts/build-iso-cu-mcp.sh).

import Foundation
import IsoGuestCU

#if os(Linux)
  GuestCUMCP.serveStdio()
#else
  FileHandle.standardError.write(
    Data("iso-cu-mcp runs in Linux guests; macOS guests use iso-macos-helper cu-mcp\n".utf8))
  exit(1)
#endif
