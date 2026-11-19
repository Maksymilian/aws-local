// ordersctl: runs the order test flows step by step (the logic-heavy scripting).
// Simple table/event helpers are Bash scripts next to template.yaml:
// generate-events.sh, clean-table.sh, show-table.sh.
//
//	go run ./tools test eventbridge [-step]
//	go run ./tools test api         [-step] [-port 3050]
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const usage = `usage: ordersctl test eventbridge|api [-step] [-port 3050]

  eventbridge   invoke the Lambda with events/*.json (sam local invoke)
  api           call the local REST API (sam local start-api)
  -step         pause before each step
  -port         port for sam local start-api (default 3050)`

func main() {
	if len(os.Args) < 3 || os.Args[1] != "test" {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	target := os.Args[2]

	fs := flag.NewFlagSet("test", flag.ExitOnError)
	step := fs.Bool("step", false, "pause before each step")
	port := fs.Int("port", 3050, "port for sam local start-api")
	_ = fs.Parse(os.Args[3:])

	chdirProjectRoot()
	r := &runner{step: *step, port: *port}

	var err error
	switch target {
	case "eventbridge":
		err = r.eventBridgeFlow()
	case "api":
		err = r.apiFlow()
	default:
		fail("unknown test target %q\n\n%s", target, usage)
	}
	if err != nil {
		fail("%v", err)
	}
}

// chdirProjectRoot makes paths like events/ and template.yaml work whether the
// tool is run from orders-test/ or orders-test/tools/.
func chdirProjectRoot() {
	for _, dir := range []string{".", ".."} {
		if _, err := os.Stat(filepath.Join(dir, "template.yaml")); err == nil {
			if err := os.Chdir(dir); err != nil {
				fail("%v", err)
			}
			return
		}
	}
	fail("run from orders-test/ (template.yaml not found)")
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
	os.Exit(1)
}
