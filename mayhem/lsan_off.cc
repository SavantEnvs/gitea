// mayhem/lsan_off.cc — preventively disable LeakSanitizer (SPEC.md §6.2 item 15).
// -fsanitize=address always bundles LSan in with no separate flag to exclude it; this hook turns
// off only leak detection at runtime init. ASan and the fuzzer's other checks stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }
