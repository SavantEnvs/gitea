// Command oracle is mayhem/test.sh's behavioral check for the fuzzed function, RenderRaw
// (code.gitea.io/gitea/modules/markup/markdown). It is a known-answer test, not a crash probe:
// a build that makes RenderRaw a no-op (or breaks its HTML sanitization) fails this even though
// nothing crashes, which is the point (SPEC.md §6.3 anti-reward-hacking).
package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"strings"

	"code.gitea.io/gitea/modules/markup"
	"code.gitea.io/gitea/modules/markup/markdown"
	"code.gitea.io/gitea/modules/setting"
)

func checkContains(name, got string, want, unwant []string) bool {
	ok := true
	for _, s := range want {
		if !strings.Contains(got, s) {
			fmt.Fprintf(os.Stderr, "FAIL %s: output missing %q\n--- output ---\n%s\n", name, s, got)
			ok = false
		}
	}
	for _, s := range unwant {
		if strings.Contains(got, s) {
			fmt.Fprintf(os.Stderr, "FAIL %s: output must not contain %q\n--- output ---\n%s\n", name, s, got)
			ok = false
		}
	}
	if ok {
		fmt.Printf("PASS %s\n", name)
	}
	return ok
}

func main() {
	markup.Init(&markup.ProcessorHelper{
		IsUsernameMentionable: func(context.Context, string) bool { return false },
	})
	setting.AppURL = "http://localhost:3000/"

	renderCtx := markup.RenderContext{
		Ctx:   context.Background(),
		Links: markup.Links{Base: "https://example.com/go-gitea/gitea"},
		Metas: map[string]string{"user": "go-gitea", "repo": "gitea"},
	}

	passed := true

	// Known-answer: a heading and GFM bold render as HTML, and a raw <script> tag is stripped
	// by RenderRaw's sanitizer — exercises both the goldmark conversion and the sanitize pass.
	var buf bytes.Buffer
	in := "# Hello Mayhem\n\nThis is **bold** text with <script>alert(1)</script> injected.\n"
	if err := markdown.RenderRaw(&renderCtx, strings.NewReader(in), &buf); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL heading-bold-sanitize: RenderRaw error: %v\n", err)
		passed = false
	} else {
		passed = checkContains("heading-bold-sanitize", buf.String(),
			[]string{"<h1", "<strong>bold</strong>"},
			[]string{"<script>"}) && passed
	}

	if !passed {
		os.Exit(1)
	}
}
