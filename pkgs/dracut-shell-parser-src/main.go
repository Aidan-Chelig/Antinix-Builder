package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

var shellBuiltins = map[string]struct{}{
	":": {}, ".": {}, "alias": {}, "bg": {}, "break": {}, "cd": {}, "command": {},
	"continue": {}, "echo": {}, "eval": {}, "exec": {}, "exit": {}, "export": {},
	"false": {}, "fc": {}, "fg": {}, "getopts": {}, "hash": {}, "jobs": {},
	"local": {}, "printf": {}, "pwd": {}, "read": {}, "readonly": {}, "return": {},
	"set": {}, "shift": {}, "test": {}, "times": {}, "trap": {}, "true": {},
	"type": {}, "typeset": {}, "ulimit": {}, "umask": {}, "unalias": {}, "unset": {},
	"[": {}, "[[": {},
}

func loadLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []string
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line != "" {
			out = append(out, line)
		}
	}
	return out, s.Err()
}

func firstCmdWord(call *syntax.CallExpr) string {
	if call == nil || len(call.Args) == 0 {
		return ""
	}
	word := call.Args[0]
	if len(word.Parts) != 1 {
		return ""
	}
	lit, ok := word.Parts[0].(*syntax.Lit)
	if !ok {
		return ""
	}
	return lit.Value
}

func writeList(path string, vals []string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	for _, v := range vals {
		if _, err := fmt.Fprintln(f, v); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintf(os.Stderr, "usage: %s <module-files.txt> <declared-commands.txt> <outdir>\n", os.Args[0])
		os.Exit(2)
	}

	moduleListPath := os.Args[1]
	declaredPath := os.Args[2]
	outDir := os.Args[3]

	files, err := loadLines(moduleListPath)
	if err != nil {
		panic(err)
	}

	declaredLines, err := loadLines(declaredPath)
	if err != nil {
		panic(err)
	}
	declared := map[string]struct{}{}
	for _, x := range declaredLines {
		declared[x] = struct{}{}
	}

	parser := syntax.NewParser(syntax.KeepComments(true))
	observed := map[string]struct{}{}
	funcNames := map[string]struct{}{}

	for _, path := range files {
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		file, err := parser.Parse(f, path)
		_ = f.Close()
		if err != nil {
			continue
		}

		syntax.Walk(file, func(node syntax.Node) bool {
			switch n := node.(type) {
			case *syntax.FuncDecl:
				funcNames[n.Name.Value] = struct{}{}
			}
			return true
		})

		syntax.Walk(file, func(node syntax.Node) bool {
			call, ok := node.(*syntax.CallExpr)
			if !ok {
				return true
			}
			name := firstCmdWord(call)
			if name == "" {
				return true
			}
			if _, ok := shellBuiltins[name]; ok {
				return true
			}
			if _, ok := funcNames[name]; ok {
				return true
			}
			if strings.HasPrefix(name, "/") || strings.Contains(name, "=") {
				return true
			}
			observed[name] = struct{}{}
			return true
		})
	}

	var observedList []string
	for x := range observed {
		observedList = append(observedList, x)
	}
	sort.Strings(observedList)

	var covered []string
	var missing []string
	for _, x := range observedList {
		if _, ok := declared[x]; ok {
			covered = append(covered, x)
		} else {
			missing = append(missing, x)
		}
	}

	if err := writeList(outDir+"/observed-commands.txt", observedList); err != nil {
		panic(err)
	}
	if err := writeList(outDir+"/covered-commands.txt", covered); err != nil {
		panic(err)
	}
	if err := writeList(outDir+"/missing-commands.txt", missing); err != nil {
		panic(err)
	}
}
