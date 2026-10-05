package main

import (
	"fmt"
	"os"

	"personalgrid/agent/internal/agent"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	stateDir, jsonOutput, commands, err := parseGlobalFlags(args)
	if err != nil {
		return err
	}
	if len(commands) == 0 || commands[0] == "help" || commands[0] == "--help" || commands[0] == "-h" {
		fmt.Printf("PersonalGrid Agent %s\nUsage: grid-agent [--state-dir PATH] [--json] <command>\nCommands: init, daemon run, network status, device list|approve|revoke|grant, confirm list|approve|deny, audit\n", agent.AgentVersion)
		return nil
	}
	return agent.RunCLI(stateDir, jsonOutput, commands)
}

func parseGlobalFlags(args []string) (string, bool, []string, error) {
	stateDir := ""
	jsonOutput := false
	commands := make([]string, 0, len(args))
	for index := 0; index < len(args); index++ {
		switch args[index] {
		case "--json":
			jsonOutput = true
		case "--state-dir":
			if index+1 >= len(args) {
				return "", false, nil, fmt.Errorf("--state-dir requires a path")
			}
			index++
			stateDir = args[index]
		case "-h", "--help":
			commands = append(commands, "help")
		default:
			commands = append(commands, args[index])
		}
	}
	return stateDir, jsonOutput, commands, nil
}
