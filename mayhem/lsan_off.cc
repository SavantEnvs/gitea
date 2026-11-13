// Disables LeakSanitizer at build time (ASan/UBSan stay on); linked into every target.
extern "C" int __lsan_is_turned_off() { return 1; }
