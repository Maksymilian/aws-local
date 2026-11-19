package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type runner struct {
	step bool
	port int
	n    int
}

// localEnv: dummy credentials so SAM never tries to refresh an AWS SSO session,
// and the project's esbuild on PATH for `sam build`.
func localEnv() []string {
	var env []string
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "AWS_PROFILE=") && !strings.HasPrefix(e, "PATH=") {
			env = append(env, e)
		}
	}
	bin, _ := filepath.Abs("node_modules/.bin")
	return append(env,
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"AWS_ACCESS_KEY_ID=local", "AWS_SECRET_ACCESS_KEY=local",
		"AWS_DEFAULT_REGION=eu-central-1", "SAM_CLI_TELEMETRY=0",
	)
}

func (r *runner) title(s string) {
	fmt.Printf("\n%s\n>>> %d. %s\n%s\n", strings.Repeat("=", 66), r.n, s, strings.Repeat("=", 66))
	r.n++
	if r.step {
		fmt.Print("press Enter...")
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	}
}

// sh runs a command with output streamed to the terminal.
func sh(name string, args ...string) error {
	fmt.Println(strings.TrimSpace("$ " + name + " " + strings.Join(args, " ")))
	cmd := exec.Command(name, args...)
	cmd.Env = localEnv()
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// shQuiet runs a command and only shows its output if it fails.
func shQuiet(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Env = localEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), err, out)
	}
	return nil
}

// The simple table operations live in Bash scripts; Go just calls them.
func cleanTable() error { return sh("./clean-table.sh") }
func showTable() error  { return sh("./show-table.sh") }

// setup: DynamoDB up, table created, Lambda built, table empty.
func (r *runner) setup() error {
	if err := sh("docker", "compose", "up", "-d", "--wait", "dynamodb-local"); err != nil {
		return err
	}
	_ = shQuiet("docker", "compose", "up", "dynamodb-init") // "table already exists" is fine
	fmt.Println("$ sam build")
	if err := shQuiet("sam", "build"); err != nil {
		return err
	}
	return cleanTable()
}

// invoke runs the Lambda with an EventBridge event file and prints its response.
func (r *runner) invoke(file string) error {
	fmt.Printf("$ sam local invoke OrderFunction -e events/%s\n", file)
	cmd := exec.Command("sam", "local", "invoke", "OrderFunction", "-e", "events/"+file)
	cmd.Env = localEnv()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("invoke %s: %w\n%s", file, err, stderr.String())
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	fmt.Printf("%s\n\n", lines[len(lines)-1])
	return nil
}

func (r *runner) eventBridgeFlow() error {
	steps := []struct {
		title string
		run   func() error
	}{
		{"Start DynamoDB, build, start from an empty table", r.setup},
		{"Create order-001 (idempotencyKey 1)", func() error { return r.invoke("01-create-order.json") }},
		{"Check DynamoDB: order-001 exists", showTable},
		{"Cancel order-001 (idempotencyKey 2)", func() error { return r.invoke("02-cancel-order.json") }},
		{"Check DynamoDB: order-001 kept, status CANCELLED", showTable},
		{"Create cancelled order-001 again (idempotencyKey 3) -> discarded", func() error { return r.invoke("03-create-order-again.json") }},
		{"Check DynamoDB: order-001 still CANCELLED", showTable},
		{"Same create twice: resend idempotencyKey 3", func() error { return r.invoke("04-create-order-duplicate.json") }},
		{"Same orderId, new idempotencyKey 4 -> 409", func() error { return r.invoke("05-create-order-conflict.json") }},
		{"Missing orderId -> 400", func() error { return r.invoke("06-missing-order-id.json") }},
		{"Missing customerId -> 400", func() error { return r.invoke("07-missing-customer-id.json") }},
		{"Check DynamoDB: still exactly one order", showTable},
		{"Remove everything", func() error {
			if err := cleanTable(); err != nil {
				return err
			}
			return showTable()
		}},
	}
	for _, s := range steps {
		r.title(s.title)
		if err := s.run(); err != nil {
			return err
		}
	}
	return nil
}

func (r *runner) apiFlow() error {
	api := fmt.Sprintf("http://127.0.0.1:%d", r.port)

	r.title("Start DynamoDB, build, start the local API Gateway, empty the table")
	if err := r.setup(); err != nil {
		return err
	}
	stop, err := startAPI(r.port)
	if err != nil {
		return err
	}
	defer stop()
	fmt.Printf("local API Gateway on %s (log: .start-api.log)\n", api)

	post := func(path, body string) func() error {
		return func() error {
			fmt.Printf("$ curl -X POST %s%s -d '%s'\n", api, path, body)
			resp, err := http.Post(api+path, "application/json", strings.NewReader(body))
			if err != nil {
				return err
			}
			defer resp.Body.Close()
			b, _ := io.ReadAll(resp.Body)
			fmt.Printf("%s\n  HTTP %d\n\n", b, resp.StatusCode)
			return nil
		}
	}

	// Same input as the EventBridge flow: the body is the event's "detail".
	create := func(file string) func() error {
		return func() error {
			body, _, err := eventDetail(file)
			if err != nil {
				return err
			}
			return post("/orders", body)()
		}
	}
	cancel := func(file string) func() error {
		return func() error {
			body, orderID, err := eventDetail(file)
			if err != nil {
				return err
			}
			return post("/orders/"+orderID+"/cancel", body)()
		}
	}

	steps := []struct {
		title string
		run   func() error
	}{
		{"Create order-001 (idempotencyKey 1)", create("01-create-order.json")},
		{"Check DynamoDB: order-001 exists, clientIp is stored", showTable},
		{"Cancel order-001 (idempotencyKey 2)", cancel("02-cancel-order.json")},
		{"Check DynamoDB: order-001 kept, status CANCELLED", showTable},
		{"Create cancelled order-001 again (idempotencyKey 3) -> discarded", create("03-create-order-again.json")},
		{"Check DynamoDB: order-001 still CANCELLED", showTable},
		{"Same create twice: resend idempotencyKey 3", create("04-create-order-duplicate.json")},
		{"Same orderId, new idempotencyKey 4 -> 409", create("05-create-order-conflict.json")},
		{"Missing orderId -> 400", create("06-missing-order-id.json")},
		{"Missing customerId -> 400", create("07-missing-customer-id.json")},
		// REST-only case (needs a different customer than any event file)
		{"Cancel by another customer -> 403", post("/orders/order-001/cancel", `{"idempotencyKey":7,"orderId":"order-001","customerId":"cust-999"}`)},
		{"Check DynamoDB: still exactly one order", showTable},
		{"Remove everything", func() error {
			if err := cleanTable(); err != nil {
				return err
			}
			return showTable()
		}},
	}
	for _, s := range steps {
		r.title(s.title)
		if err := s.run(); err != nil {
			return err
		}
	}
	return nil
}

// startAPI runs `sam local start-api` in the background and waits until it listens.
// The returned func stops it (and the Lambda containers it spawned).
func startAPI(port int) (func(), error) {
	logFile, err := os.Create(".start-api.log")
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("sam", "local", "start-api", "--port", fmt.Sprint(port), "--warm-containers", "EAGER")
	cmd.Env = localEnv()
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own process group, killed as a whole
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan struct{}) // closed when sam exits
	go func() { _ = cmd.Wait(); close(done) }()
	stop := func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		<-done
		_ = logFile.Close()
	}

	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		log, _ := os.ReadFile(".start-api.log")
		switch {
		case bytes.Contains(log, []byte("Running on")):
			return stop, nil
		case bytes.Contains(log, []byte("Address already in use")):
			stop()
			return nil, fmt.Errorf("port %d is in use, pick another with -port", port)
		}
		select {
		case <-done:
			return nil, fmt.Errorf("sam local start-api exited, see .start-api.log")
		case <-time.After(500 * time.Millisecond):
		}
	}
	stop()
	return nil, fmt.Errorf("sam local start-api did not start within 3 minutes")
}

// eventDetail returns the "detail" of events/<file> as compact JSON, plus its orderId.
func eventDetail(file string) (string, string, error) {
	raw, err := os.ReadFile(filepath.Join("events", file))
	if err != nil {
		return "", "", err
	}
	var ev struct {
		Detail json.RawMessage `json:"detail"`
	}
	if err := json.Unmarshal(raw, &ev); err != nil {
		return "", "", fmt.Errorf("%s: %w", file, err)
	}
	var d struct {
		OrderID string `json:"orderId"`
	}
	_ = json.Unmarshal(ev.Detail, &d)
	var buf bytes.Buffer
	if err := json.Compact(&buf, ev.Detail); err != nil {
		return "", "", err
	}
	return buf.String(), d.OrderID, nil
}
