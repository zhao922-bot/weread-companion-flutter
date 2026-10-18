#include <flutter/dart_project.h>
#include "flutter_window.h"

namespace flutter { class PluginRegistry; }
void RegisterPlugins(flutter::PluginRegistry*) {}

class ProbeWindow : public FlutterWindow {
 public:
  using FlutterWindow::FlutterWindow;
  using FlutterWindow::MessageHandler;
};

int main() {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  flutter::DartProject project(L"data");
  ProbeWindow window(project);
  // Windows can broadcast font changes before the Flutter controller exists,
  // or while tearing it down. Neither message may dereference a null engine.
  window.MessageHandler(nullptr, WM_FONTCHANGE, 0, 0);
  window.Destroy();
  window.MessageHandler(nullptr, WM_FONTCHANGE, 0, 0);
  return 0;
}
