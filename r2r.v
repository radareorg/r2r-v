module main

import (
	os
	sync
	time
	term
	json
	flag
	radare.r2
)

/*
 fn C.r_cons_begin() bool
 fn C.r_cons_is_breaked() bool
 fn C.r_cons_break_push(a, b voidptr) bool
 fn C.r_cons_break_pop() bool
*/

const (
	default_jobs = 2
	default_targets = 'arch json asm fuzz cmd unit'
	default_timeout = 10
	default_asm_bits = 32
	default_radare2 = 'radare2'
	default_dbpath = 'new/db' // XXX use execpath as relative reference to it
	cmd_test_paths = ['cmd', 'extras', 'tools'] // all dirs under db/ that contain regular command tests
	r2r_version = '0.2'
)

fn autodetect_dbpath() string {
	return os.join_path(r2r_home(),default_dbpath)
}

fn r2r_home() string {
	home := os.base_dir(os.real_path(os.executable()))
	return os.join_path(home,'..')
}

fn control_c() {
	println('\nInterrupted.')
	exit(1)
}

pub fn main() {
	mut r2r := R2R{}
	mut fp := flag.new_flag_parser(os.args)
	fp.application(os.file_name(os.executable()))
	// fp.version(r2r_version)
	show_norun := fp.bool('norun', `n`, false, 'Dont run the tests')
	show_help := fp.bool('help', `h`, false, 'Show this help screen')
	r2r.jobs = fp.int('jobs', `j`, default_jobs, 'Spawn N jobs in parallel to run tests ($default_jobs).' +
	                                              ' Set to 0 for 1 job per test.')
	r2r.timeout = fp.int('timeout', `t`, default_timeout, 'How much time to wait to consider a fail ($default_timeout)')
	show_version := fp.bool('version', `v`, false, 'Show version information')
	r2r.r2r_home = r2r_home()
	r2r.show_quiet = fp.bool('quiet', `q`, false, 'Silent output of OK tests')
	r2r.interactive = fp.bool('interactive', `i`, false, 'Prompt to manually fix failing tests (TODO)')
	r2r.db_path = fp.string('dbpath', `d`, autodetect_dbpath(), 'Set database path db/')
	r2r.r2_path = fp.string('r2', `r`, default_radare2, 'Set path/name to radare2 executable')
	if show_help {
		println(fp.usage())
		println('ARGS:')
		println('  ${default_targets}')
		println('  or path/to/test/file')
		println('\nExamples:')
		println('  \$ r2r cmd /write       run only the cmd tests in the /write file')
		println('  \$ time r2r -n          benchmark time spent parsing test files')
		println('  \$ r2r -j 4 json asm    run json and asm tests using 4 jobs in parallel')
		return
	}
	if show_version {
		println(r2r_version)
		return
	}
	if r2r.jobs < 0 {
		eprintln('Invalid number of thread selected with -j')
		exit(1)
	}
	args := fp.finalize() or {
		eprintln('Error: ' + err)
		exit(1)
	}
	r2r.targets = args[1..]
	for a in r2r.targets {
		a.index('/') or { continue }
		r2r.filter_by_files << a
	}

	if r2r.interactive {
		eprintln('Warning: interactive mode not yet implemented in V. Use the node testsuite for this')
		p := os.join_path(r2r.r2r_home,'new')
		if !os.is_dir(os.join_path(p,'node_modules')) {
			exit(1)
		}
		a := r2r.targets.join(' ')
		_ = os.system('cd $p && npm i')
		r := os.system('cd $p && node_modules/.bin/r2r -i $a')
		exit(r)
	}
	if r2r.targets.index('help') != -1 {
		eprintln(default_targets)
		exit(0)
	}
	println('[r2r] Loading tests')
	r2r.load_tests()
	if !show_norun {
		r2r.run_tests()
		r2r.show_report()
	}
	rc := r2r.return_code()
	exit(rc)
}

fn (r2r mut R2R) run_tests() {
	if r2r.wants('json') {
		r2r.run_jsn_tests()
	}
	if r2r.wants('unit') {
		r2r.run_unit_tests()
	}
	if r2r.wants('asm') {
		r2r.run_asm_tests()
	}
	if r2r.wants('fuzz') {
		r2r.run_fuz_tests()
	}
	if r2r.wants_any_cmd_tests() {
		r2r.run_cmd_tests()
	}
}

// make a PR for V to have this in os.mktmpdir()
fn C.mkdtemp(template charptr) byteptr


fn mktmpdir(template string) string {
	tp := if template == '' { 'temp.XXXXXX' } else { template }
	dir := os.join_path(os.temp_dir(),tp)
	res := C.mkdtemp(dir.str)
	return tos_clone(res)
}

// ///////////////
struct R2R {
mut:
	cmd_tests   []R2RCmdTest
	asm_tests   []R2RAsmTest
	targets     []string
	r2          &r2.R2
	jobs        int
	timeout     int
	wg          &sync.WaitGroup
	success     int
	failed      int
	fixed       int
	broken      int
	db_path     string
	r2_path     string
	show_quiet  bool
	interactive bool
	r2r_home    string
	filter_by_files []string
}

fn (r2r R2R)return_code() int {
	if r2r.failed == 0 {
		return 0
	}
	return 1
}

struct R2RCmdTest {
mut:
	name       string
	file       string
	args       string
	source     string
	cmds       string
	expect     string
	expect_err string
	// mutable
	broken     bool
	failed     bool
	fixed      bool
}

struct R2RAsmTest {
mut:
	arch string
	bits int
	mode string
	inst string
	data string
	offs u64
	bige bool
	cpu  string
}

// TODO: not yet used
struct R2JsonTest {
mut:
	name string
}

fn (test R2RCmdTest) parse_slurp(v string) (string,string) {
	mut res := ''
	mut slurp_token := ''
	if v.starts_with("'") || v.starts_with("'") {
		eprintln('Warning: Deprecated syntax, use <<EOF in ${test.source} @ ${test.name}')
	}
	else if v.starts_with('<<') {
		slurp_token = v[2..v.len]
		if slurp_token == 'RUN' {
			eprintln('Warning: Deprecated <<RUN, use <<EOF in ${test.source} @ ${test.name}')
		}
	}
	else {
		res = v[0..v.len]
	}
	return res,slurp_token
}

fn (r2r mut R2R) load_cmd_test(testfile string) {
	if r2r.filtered_file(testfile) {
		return
	}
	mut test := R2RCmdTest{}
	lines := os.read_lines(testfile) or {
		panic(err)
	}
	mut slurp_target := &test.cmds
	mut slurp_token := ''
	mut slurp_data := ''
	test.source = testfile
	for line in lines {
		if slurp_token.len > 0 {
			if line == slurp_token {
				*slurp_target = slurp_data
				slurp_data = ''
				slurp_token = ''
			}
			else {
				slurp_data += '${line}\n'
			}
			continue
		}
		if line.len == 0 {
			continue
		}
		kv := line.split_nth('=', 2)
		if kv.len == 0 {
			continue
		}
		k := kv[0]
		v := if kv.len == 2 { kv[1] } else { '' }
		match k {
			'CMDS' {
				if v.len > 0 {
					a,b := test.parse_slurp(v)
					test.cmds = a
					slurp_token = b
					if slurp_token.len > 0 {
						slurp_target = &test.cmds
					}
				}
				else {
					panic('Warning: Missing arg to CMDS')
				}
			}
			'EXPECT' {
				if v.len > 0 {
					a,b := test.parse_slurp(v)
					test.expect = a
					slurp_token = b
					if slurp_token.len > 0 {
						slurp_target = &test.expect
					}
				}
				else {
					eprintln('Warning: Missing value for EXPECT')
				}
			}
			'EXPECT_ERR' {
				if v.len > 0 {
					a,b := test.parse_slurp(v)
					test.expect_err = a
					slurp_token = b
					if slurp_token.len > 0 {
						slurp_target = &test.expect_err
					}
				}
				else {
					eprintln('Warning: Missing value for EXPECT_ERR')
				}
			}
			'BROKEN' {
				if v.len > 0 {
					test.broken = v[0] != `0`
				}
				else {
					eprintln('Warning: Missing value for BROKEN in ${test.source}')
				}
			}
			'ARGS' {
				if v.len > 0 {
					test.args = line[5..line.len]
				}
				else {
					eprintln('Warning: Missing value for ARGS in ${test.source}')
				}
			}
			'FILE' {
				test.file = line[5..]
			}
			'NAME' {
				test.name = line[5..]
				// XXX this is slow. we need a hashtable for O(1)
				for t in r2r.cmd_tests {
					if t.name == test.name {
						eprintln('Warning: Duplicated test name "${t.name}" in test.source')
					}
				}
			}
			'RUN' {
				if v.len > 0 {
					eprintln('Warning: RUN statement doesnt require a value')
				}
				if test.name.len == 0 {
					eprintln('Warning: Invalid test name in ${test.source}')
				}
				else {
					if test.name == '' {
						eprintln('No test name to run')
					}
					else {
						if test.file == '' {
							test.file = '-'
						}
						r2r.cmd_tests << test
					}
					test = R2RCmdTest{}
					test.source = testfile
				}
			}
			else {}
		}
	}
}

/*
// only useful for r2pipe mode, right now we do plain spawns with pipes

fn (r2r R2R)run_commands(test R2RCmdTest) string {
	res := ''
	for cmd in cmds {
		if isnil(cmd) {
			continue
		}
		res += r2r.r2.cmd(cmd)
	}
	return res
}
*/

fn (r2r mut R2R) test_failed(test R2RCmdTest, a string, b string) string {
	if test.broken {
		r2r.broken++
		return term.blue('BR')
	}
	println('# File: ${test.file}')
	println(term.ok_message(test.cmds))
	println(term.fail_message(a))
	println('# ----')
	println(term.ok_message(b))
	r2r.failed++
	return term.red('XX')
}

fn (r2r R2R) wants(s string) bool {
	// eprintln('want ${s}')
	if s.contains('/') {
		return true
	}
	if r2r.targets.len < 1 {
		return true
	}
	return r2r.targets.index(s) != -1
}

fn (r2r R2R) wants_any_cmd_tests() bool {
	if r2r.filter_by_files.len > 0 {
		return true
	}
	if r2r.wants('arch') {
		return true
	}
	for cmd_test_path in cmd_test_paths {
		if r2r.wants(cmd_test_path) {
			return true
		}
	}
	return false
}

fn (r2r mut R2R) test_fixed(test R2RCmdTest) string {
	r2r.fixed++
	return term.yellow('FX')
}

fn (r2r mut R2R) run_asm_test_native(test R2RAsmTest, dismode bool) {
	r2r.r2.break_begin()
	test_expect := if dismode { test.inst.trim_space() } else { test.data.trim_space() }
	time_start := time.ticks()
	r2r.r2.cmd('e asm.arch=${test.arch}')
	r2r.r2.cmd('e asm.bits=${test.bits}')
	if test.cpu != '' {
		r2r.r2.cmd('e asm.cpu=${test.cpu}')
	}
	if test.offs != 0 {
		r2r.r2.cmd('s ${test.offs}')
	}
	else {
		r2r.r2.cmd('s 0')
	}

	be := if test.mode.contains('E') { 'true' } else { 'false' }
	r2r.r2.cmd('e cfg.bigendian=${be}')

	res := r2r.r2.cmd(if dismode { '"pad ${test.data}"' } else { '"pa ${test.inst}"' })

	mut mark := term.green('OK')
	if res.trim_space() == test_expect {
		if test.mode.contains('B') {
			mark = term.yellow('FX')
			r2r.fixed++
		} else {
			r2r.success++
		}
	}
	else {
		if test.mode.contains('B') {
			mark = term.blue('BR')
			r2r.broken++
		}
		else {
			mark = term.red('XX')
			r2r.failed++
		}
	}
	time_end := time.ticks()
	times := time_end - time_start
	if !r2r.show_quiet || !mark.contains('OK') {
		println('[${mark}] ${test.mode} (time ${times}) ${test.arch} ${test.bits} : ${test.data} ${test.inst}')
	}
	if r2r.r2.break_end() {
		eprintln('Interrupted')
		exit(1)
	}
	r2r.wg.done()
}

fn (r2r mut R2R) run_asm_test(test R2RAsmTest, dismode bool) {
	if !isnil(r2r.r2) {
		r2r.run_asm_test_native(test, dismode)
		return
	}
	// TODO: use the r2 api instead of spawning all the time
	mut args := []string
	args << '-a ${test.arch}'
	args << '-b ${test.bits}'
	if test.cpu != '' {
		args << '-c ${test.cpu}'
	}
	if test.offs != 0 {
		args << '-o ${test.offs}'
	}
	if test.mode.contains('E') {
		args << '-e'
	}
	if dismode {
		args << '-d'
		args << test.data
	}
	else {
		args << '"${test.inst}"'
	}
	rasm2_flags := args.join(' ')
	time_start := time.ticks()
	tmp_dir := mktmpdir('')
	tmp_output := os.join_path(tmp_dir,'output.txt')
	os.system('rasm2 ${rasm2_flags} > ${tmp_output}')
	res := os.read_file(tmp_output) or {
		panic(err)
	}
	os.rm(tmp_output)
	os.rmdir(tmp_dir)
	mut mark := term.green('OK')
	test_expect := if dismode { test.inst.trim_space() } else { test.data.trim_space() }
	if res.trim_space() == test_expect {
		if test.mode.contains('B') {
			mark = term.yellow('FX')
		}
	}
	else {
		if test.mode.contains('B') {
			mark = term.blue('BR')
		}
		else {
			mark = term.red('XX')
		}
	}
	time_end := time.ticks()
	times := time_end - time_start
	println('[${mark}] ${test.mode} (time ${times}) ${test.arch} ${test.bits} : ${test.data} ${test.inst}')
	r2r.wg.done()
}

fn handle_control_c() {
	$if windows {
		// ^C not handled on windows
	} $else {
		os.signal(C.SIGINT, control_c)
	}
}

fn (r2r mut R2R) run_cmd_test(test R2RCmdTest) {
	time_start := time.ticks()
	tmp_dir := mktmpdir('')
	tmp_script := os.join_path(tmp_dir,'script.r2')
	tmp_stderr := os.join_path(tmp_dir,'stderr.txt')
	tmp_output := os.join_path(tmp_dir,'output.txt')
	os.write_file(tmp_script, test.cmds)
	// TODO: handle timeout
	r2 := '${r2r.r2_path} -e scr.utf8=0 -e scr.interactive=0 -e scr.color=0 -NQ'
	cwd := os.getwd()
	os.chdir('../new') // fix runnig directory
	os.system('${r2} -i ${tmp_script} ${test.args} ${test.file} 2> ${tmp_stderr} > ${tmp_output}')
	os.chdir(cwd)
	res := os.read_file(tmp_output) or {
		panic(err)
	}
	errstr := os.read_file(tmp_stderr) or {
		panic(err)
	}
	os.rm(tmp_script)
	os.rm(tmp_output)
	os.rm(tmp_stderr)
	os.rmdir(tmp_dir)
	mut mark := term.green('OK')
	test_expect := test.expect.trim_space()
	if res.trim_space() != test_expect {
		mark = r2r.test_failed(test, test_expect, res)
	}
	else {
		if test.expect_err != '' && errstr.trim_space() != test.expect_err.trim_space() {
			mark = r2r.test_failed(test, test.expect_err, errstr)
		}
		else if test.broken {
			mark = r2r.test_fixed(test)
		}
		else {
			r2r.success++
		}
	}
	handle_control_c()
	time_end := time.ticks()
	times := time_end - time_start
	println('[${mark}] (time ${times}) ${test.source} : ${test.name}')
	// count results
	r2r.wg.done()
}

fn (r2r mut R2R) run_fuz_test(ff string, pc int) bool {
	handle_control_c()
	cmd := 'rarun2 timeout=${default_timeout} system="${r2r.r2_path} -qq -A -n ${ff}"'
	res := os.system(cmd) == 0
	handle_control_c()

	mark := if res { term.green('OK') } else { term.red('XX') }
	if res {
		r2r.success++
	} else {
		r2r.failed++
	}
	if !r2r.show_quiet || !res {
		println('[${mark}] ${pc}% ${ff}')
	}
	r2r.wg.done()
	return res
}

fn (r2r R2R) git_clone(ghpath, localpath string) {
	os.system('cd ${r2r.db_path}/.. ; git clone --depth 1 https://github.com/${ghpath} ${localpath}')
}

fn (r2r mut R2R) run_fuz_tests() {
	home := r2r_home()
	fuzz_path := '${home}/bins/fuzzed'
	r2r.wg = sync.new_waitgroup()
	// open and analyze all the files in bins/fuzzed
	if !os.is_dir(fuzz_path) {
		r2r.git_clone('radareorg/radare2-testbins', 'bins')
		r2r.git_clone('radareorg/radare2-fuzztargets', 'fuzz/targets')
	}
	files := os.ls(fuzz_path) or {
		panic(err)
	}
	mut c := r2r.jobs
	mut n := 0
	t := files.len
	for file in files {
		ff := os.join_path(fuzz_path, file)
		pc := n * 100 / t
		handle_control_c()
		r2r.wg.add(1)
		go r2r.run_fuz_test(ff, pc)
		c--
		if c == 0 {
			handle_control_c()
			r2r.wg.wait()
			c = r2r.jobs
		}
		n++
	}
	r2r.wg.wait()
}

fn (r2r mut R2R) load_asm_test(testfile string) {
	lines := os.read_lines(testfile) or {
		panic(err)
	}
	for line in lines {
		if line.len == 0 || line.starts_with('#') {
			continue
		}
		words := line.split('"')
		if words.len == 3 {
			mut at := R2RAsmTest{}
			at.mode = words[0].trim_space()
			at.inst = words[1].trim_space()
			data := words[2].trim_space()
			if data.contains(' ') {
				w := data.split(' ')
				at.data = w[0].trim_space()
				at.offs = w[1].trim_space().u64()
			}
			else {
				at.data = data
			}
			abs := testfile.split('/')
			values := abs[abs.len - 1].split('_')
			if values.len == 1 {
				at.arch = values[0]
				at.bits = default_asm_bits
			}
			else if values.len == 2 {
				at.arch = values[0]
				at.bits = values[1].int()
			}
			else if values.len == 3 {
				at.arch = values[0]
				at.cpu = values[1]
				at.bits = values[2].int()
			}
			else {
				eprintln('Warning: Invalid asm/cpu/bits filename ${abs}')
			}
			if at.bits == 0 {
				eprintln('Warning: Invalid asm.bits settings in ${abs}')
				at.bits = default_asm_bits
			}
			r2r.asm_tests << at
		}
		else {
			eprintln('Warning: Invalid asm test for ${testfile} in ${line}')
		}
	}
}

fn (r2r mut R2R) load_asm_tests(testpath string) {
	r2r.wg = sync.new_waitgroup()
	files := os.ls(testpath) or {
		panic(err)
	}
	for file in files {
		if file.starts_with('.') {
			continue
		}
		f := os.join_path(testpath,file)
		if os.is_dir(f) {
			r2r.load_asm_tests(f)
		}
		else {
			r2r.load_asm_test(f)
		}
	}
	r2r.wg.wait()
}

fn (r2r mut R2R) run_unit_tests() bool {
	wd := os.getwd()
	_ = os.system('make -C ${r2r.r2r_home}/unit') // TODO: rewrite in V instead of depending on a makefile
	unit_path := '${r2r.db_path}/../../unit/bin'
	unit_home := '${r2r.db_path}/../..'
	if !os.is_dir(unit_path) {
		eprintln('Cannot open unit_path')
		return false
	}
	os.chdir(unit_home)
	println('[r2r] Running unit tests from ${unit_path}')
	files := os.ls(unit_path) or {
		return false
	}
	for file in files {
		fpath := os.join_path(unit_path, file)
		if is_executable(fpath, file) {
			// TODO: filter OK
			cmd := if r2r.show_quiet { '(${fpath} ;echo \$? > .a) | grep -v OK || [ "\$(shell cat .a)" = 0 ]' } else { '$fpath' }
			if os.system(cmd) == 0 {
				r2r.success++
			}
			else {
				r2r.failed++
			}
		}
	}
	os.chdir(wd)
	return true
}

fn is_executable(abspath, filename string) bool {
	if filename.starts_with('r2-') {
		return false
	}
	if os.is_dir(abspath) {
		return false
	}
	return os.is_executable(abspath)
}

fn (r2r mut R2R) run_asm_tests() {
	mut c := r2r.jobs
	r2r.r2 = r2.new()
	// assemble/disassemble and compare
	for at in r2r.asm_tests {
		if at.mode.contains('a') {
			r2r.wg.add(1)
			if isnil(r2r.r2) {
				go r2r.run_asm_test(at, false)
			}
			else {
				r2r.run_asm_test(at, false)
			}
			if r2r.jobs > 0 {
				c--
				if c < 1 {
					r2r.wg.wait()
					c = r2r.jobs
				}
			}
		}
		if at.mode.contains('d') {
			r2r.wg.add(1)
			if isnil(r2r.r2) {
				go r2r.run_asm_test(at, true)
			}
			else {
				r2r.run_asm_test(at, true)
			}
			if r2r.jobs > 0 {
				c--
				if c < 1 {
					r2r.wg.wait()
					c = r2r.jobs
				}
			}
		}
	}
	r2r.wg.wait()
}

fn (r2r mut R2R) run_jsn_tests() {
	json_path := '${r2r.db_path}/json'
	files := os.ls(json_path) or {
		panic(err)
	}
	for file in files {
		f := os.join_path(json_path,file)
		lines := os.read_lines(f) or {
			panic(err)
		}
		for line in lines {
			if line.trim_space().len == 0 {
				continue
			}
			ok := r2r.run_jsn_test(line)
			mut mark := term.green('OK')
			if ok {
				r2r.success++
			}
			else {
				if line.contains('BROKEN') {
					mark = term.blue('BR')
					r2r.broken++
				}
				else {
					mark = term.red('XX')
					r2r.failed++
				}
			}
			if !ok || !r2r.show_quiet {
				println('[${mark}] json ${line}')
			}
		}
	}
}

fn (r2r R2R)filtered_file(file string) bool {
	if r2r.filter_by_files.len == 0 {
		return false
	}
	for fbf in r2r.filter_by_files {
		if file.ends_with(fbf) {
			return false
		}
	}
	return true
}

fn (r2r mut R2R) run_cmd_tests() {
	println('[r2r] Running cmd tests')
	// r2r.r2 = r2.new()
	// TODO: use lock
	r2r.wg = sync.new_waitgroup()
	println('Adding ${r2r.cmd_tests.len} watchgooses')
	// r2r.wg.add(r2r.cmd_tests.len)
	mut c := r2r.jobs
	for t in r2r.cmd_tests {
		if r2r.filtered_file(t.source) {
			continue
		}
		handle_control_c()
		r2r.wg.add(1)
		go r2r.run_cmd_test(t)
		if r2r.jobs > 0 {
			c--
			if c < 1 {
				r2r.wg.wait()
				c = r2r.jobs
			}
		}
	}
	r2r.wg.wait()
}

fn (r2r R2R) show_report() {
	total := r2r.broken + r2r.fixed + r2r.failed + r2r.success
	println('')
	println(' Broken: ${r2r.broken}')
	println('  Fixed: ${r2r.fixed}')
	println('Success: ${r2r.success}')
	println(' Failed: ${r2r.failed}')
	println('  Total: ${total}')
}

fn (r2r mut R2R) load_cmd_tests(testpath string) {
	files := os.ls(testpath) or {
		panic(err)
	}
	for file in files {
		if file.starts_with('.') {
			continue
		}
		f := os.join_path(testpath, file)
		if os.is_dir(f) {
			r2r.load_cmd_tests(f)
		}
		else {
			r2r.load_cmd_test(f)
		}
	}
}

struct DummyStruct {
	no string
}

fn (r2r mut R2R) run_jsn_test(cmd string) bool {
	if isnil(r2r.r2) {
		r2r.r2 = r2.new()
		// _ = r2r.r2.cmd('o /bin/ls')
	}
	jsonstr := r2r.r2.cmd(cmd)
	if jsonstr.trim_space() == '' {
		return true
	}
	// verify json
	_ = json.decode(DummyStruct,jsonstr) or {
		eprintln('[r2r] json ${cmd} = ${jsonstr}')
		return false
	}
	return true
	// return os.system("echo '${jsonstr}' | jq . > /dev/null") == 0
}

fn (r2r R2R) load_jsn_tests(testpath string) {
	// implementation is in run_jsn_tests
	// nothing to load for now
}

fn (r2r mut R2R) load_tests() {
	r2r.cmd_tests = []
	if !os.is_dir(r2r.db_path) {
		eprintln('Cannot open -d ${r2r.db_path}')
		return
	}
	if r2r.wants('json') {
		r2r.load_jsn_tests('${r2r.db_path}/json')
	}
	if r2r.wants('asm') {
		r2r.load_asm_tests('${r2r.db_path}/asm')
	}
	for f in r2r.filter_by_files {
		if os.exists(f) {
			r2r.load_cmd_test(f)
		}
	}
	for cmd_test_path in cmd_test_paths {
		if r2r.wants(cmd_test_path) {
			r2r.load_cmd_tests('${r2r.db_path}/${cmd_test_path}')
		}
	}
	if r2r.wants('arch') {
		$if x64 {
			$if linux {
			  p := '${r2r.db_path}/archos'
				r2r.load_cmd_tests('$p/linux-x64/')
			} $else {
				$if macos {
					p := '${r2r.db_path}/archos'
					r2r.load_cmd_tests('$p/darwin-x64/')
				} $else {
					eprintln('Warning: archos tests not supported for current platform')
				}
			}
		} $else {
			eprintln('Warning: archos tests not supported for current platform')
		}
	}
}
