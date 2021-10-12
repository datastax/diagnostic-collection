/*
 * Copyright DataStax, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/********************************************************************************************************
 *
 * Rust program to collect diagnostic information by calling a list of shell commands.
 *
 * Keep this as entry-level rust as possible (basic language and only compile with rustc, no Crates, no Cargo).
 *
 * It needs to be easily audited by operators and deemed safe, before running production environments.
 * This also makes this file an easy introduction to Rust for the maintainers.
 ********************************************************************************************************/

use std::collections::HashSet;
use std::env;
use std::fs::File;
use std::io;
use std::io::prelude::*;
use std::path::Path;
use std::process::Command;
use std::process::Stdio;
use std::str::FromStr;

const DRY_RUN: bool = false;

/** See Options struct for ordered list of arguments to pass in
 * eg `collect-info "$server_pid" "$artifactDir"
 **/
fn main() {
    let args: Vec<String> = env::args().collect();
    assert!(3 == args.len(), "Unexpected number of arguments ({}), should be 2 ($server_pid $artifactDir)", args.len());

    // all mandatory parameters are command line arguments
    // all parameters with defaults (or contain sensitive info) are environment variables 
    let options: Options = Options {
        base_dir: &env::var("baseDir").unwrap_or("/tmp/datastax".to_string()),
        artifact_dir: &args[2],
        skip_sudo: bool::from_str(&env::var("skipSudo").unwrap_or("false".to_string())).unwrap(),
        log_home: &env::var("logHome").unwrap_or("/var/log/cassandra".to_string()),
        data_dir: &env::var("data_dir").unwrap_or("".to_string()),
        config_home: &env::var("configHome").unwrap_or("/etc/cassandra".to_string()),
        cassandra_pid: &args[1],
        prometheus_jar: &env::var("prometheus_jar").unwrap_or("none.jar".to_string()),
        jmx_port: &env::var("jmxPort").unwrap_or("7199".to_string()),
        jmx_username: &env::var("jmxUsername").unwrap_or("".to_string()),
        jmx_password: &env::var("jmxPassword").unwrap_or("".to_string()),
        nodetool_host:  &env::var("nodetoolHost").unwrap_or("".to_string()),
        nodetool_credentials: &env::var("nodetoolCredentials").unwrap_or("".to_string()),
        cqlsh_host:  &env::var("cqlsh_host").unwrap_or("localhost".to_string()),
        cqlsh_opts: &env::var("cqlshOpts").unwrap_or("".to_string()),
        cqlsh_password: &env::var("cqlshPassword").unwrap_or("".to_string()),
        timeout_opts: &env::var("timeout_opts").unwrap_or("".to_string()),
        dse_bin_dir: &env::var("dse_bin_dir").unwrap_or("".to_string()),
        dt_opts: &env::var("dt_opts").unwrap_or("".to_string()),
        solr_data_dir: &env::var("solr_data_dir").unwrap_or("".to_string()),
    };

    check_all_commands(&options);
    execute_all_commands(&options);
}

fn check_all_commands(options: &Options) {
    println!("Checking commands required to collect information…");

    let mut checked_commands = HashSet::new();
    COMMANDS.iter().enumerate().for_each(|(_i, cmd)| {

        let cmd_str = format_command(cmd.command, options);
        if !checked_commands.contains(&cmd_str) {
            checked_commands.insert(cmd_str.clone());

            print!("\tlooking for `{}`… ", cmd_str);
            io::stdout().flush().ok().expect("Could not flush stdout");

            let result = check_command(cmd, &options);
            if result.0 {
                println!("FOUND at {}", result.1.replace("\n", ""));
            } else {
                println!("missing");
                if !cmd.optional {
                    println!(
                        "FATAL: {} not found and is not optional for the collector",
                        cmd_str
                    )
                }
            }
        }
    });
    println!(" …OK");
}

fn execute_all_commands(options: &Options) {
    println!("Collecting OS information… ");

    let auditor: File = create_auditor_file(&options);

    COMMANDS.iter().enumerate().for_each(|(_i, cmd)| {
        let cmd_str = format_command(cmd.command, options);
        let args_str = format_args(cmd.args, options, true);

        if !cmd.optional || check_command(cmd, &options).0 {
            print!("\texecuting `{} {} > {}`… ", cmd_str, args_str, cmd.file);
            io::stdout().flush().ok().expect("Could not flush stdout");

            if !should_skip_command(cmd) {
                if DRY_RUN || execute_command(cmd, options, &auditor) {
                    println!("OK");
                } else {
                    println!("failed");
                    assert!(cmd.optional);
                }
            } else {
                println!("skipped");
            }
        } else {
            println!("\tskipping  `{} {}`", cmd_str, args_str);
        }
    });

    println!(" …OK");
}

fn create_auditor_file(options: &Options) -> File {
    let auditor_str = &format!("{}/collect-info.audit.log", options.artifact_dir);
    let auditor_path = Path::new(&auditor_str);
    std::fs::create_dir_all(auditor_path.parent().unwrap()).unwrap();
    File::create(&auditor_path).expect("failed to create file collect-info.audit.log")
}

fn should_skip_command(cmd: &Cmd) -> bool {
    let mut skip = false;
    for skip_flag in cmd.skip_flags.split_whitespace() {
        let val = env::var(skip_flag);
        skip |= val.is_ok() && FromStr::from_str(&val.unwrap()).unwrap();
    }
    skip
}

fn check_command(cmd: &Cmd, options: &Options) -> (bool, String) {
    let cmd_str = format_command(cmd.command, options);

    let result = create_command("sh", &cmd, &options)
        .arg("-c")
        .arg(format!("command -v {}", cmd_str))
        .output()
        .expect(format!("failed to execute `sh -c command -v {}`", cmd_str).as_str());
        
    (result.status.success(), std::str::from_utf8(&result.stdout).unwrap().to_string())
}

fn execute_command(cmd: &Cmd, options: &Options, mut auditor: &File) -> bool {
    assert!(!DRY_RUN);
    let cmd_str = format_command(cmd.command, options);
    let args_str = format_args(cmd.args, options, true);

    write!(auditor, "{} {} > {}\n", cmd_str, args_str, cmd.file).expect(
        format!(
            "failed auditing `{} {} > {}`",
            cmd_str, args_str, cmd.file
        )
        .as_str(),
    );

    let mut command = create_command(&cmd_str, &cmd, &options);
    if !cmd.args.is_empty() {
        command.args(format_args(cmd.args, options, false).split_whitespace());
    }
    assert!(!cmd.file.is_empty() || !cmd.use_sudo, "use_sudo cannot be used when cmd.file is empty (`{} {}`)", cmd_str, args_str);
    if let Some(file) = create_command_output_file(options.artifact_dir, cmd.file) {
        if cmd.use_stdout {
            command.stdout(Stdio::from(file));
        } else {
            command.stderr(Stdio::from(file));
        }
    }
    command
        .status()
        .expect(format!("failed to collect command `{} {}`", cmd_str, args_str).as_str())
        .success()
}

fn format_command(cmd: &str, options: &Options) -> String {
    cmd.replace("{base_dir}", options.base_dir)
        .replace("{dse_bin_dir}", options.dse_bin_dir)
}

fn format_args(args: &str, options: &Options, mask: bool) -> String {
    args.replace("{artifact_dir}", options.artifact_dir)
        .replace("{log_home}", options.log_home)
        .replace("{data_dir}", options.data_dir)
        .replace("{config_home}", options.config_home)
        .replace("{cassandra_pid}", options.cassandra_pid)
        .replace("{prometheus_jar}", options.prometheus_jar)
        .replace("{jmx_port}", options.jmx_port)
        .replace("{jmx_username}", options.jmx_username)
        .replace("{jmx_password}", &format_jmx_password(&options.jmx_password, mask))
        .replace("{nodetool_host}", options.nodetool_host)
        .replace("{nodetool_credentials}", &format_jmx_password(&options.nodetool_credentials, mask))
        .replace("{cqlsh_host}", options.cqlsh_host)
        .replace("{cqlsh_opts}", &format_cqlsh_opts(&options.cqlsh_opts, options.cqlsh_password, mask))
        .replace("{dt_opts}", options.dt_opts)
        .replace("{solr_data_dir}", options.solr_data_dir)
}

fn format_jmx_password(jmx_password: &str, mask: bool) -> String {
    if mask {
        "****".to_string()
    } else {
        jmx_password.to_string()
    }
}

fn format_cqlsh_opts(cqlsh_opts: &str, cqlsh_password: &str, mask: bool) -> String {
    if mask {
        cqlsh_opts.replace(cqlsh_password, "****")
    } else {
        cqlsh_opts.to_string()
    }
}

fn create_command(cmd_str: &str, cmd: &Cmd, options: &Options) -> Command {
    if cmd.use_sudo && !options.skip_sudo {
        let mut command = Command::new("sudo");
        if cmd.use_timeout {
            command.arg("timeout");
            command.args(options.timeout_opts.split_whitespace());
        }
        command.arg(cmd_str);
        command
    } else {
        if cmd.use_timeout {
            let mut command = Command::new("timeout");
            command.args(options.timeout_opts.split_whitespace());
            command.arg(cmd_str);
            command
        } else {
            Command::new(cmd_str)
        }
    }
}

fn create_command_output_file(artifact_dir: &str, cmd_file: &str) -> Option<File> {
    if cmd_file.is_empty() {
        None
    } else {
        let path_str: &String = &format!("{}/{}", artifact_dir, cmd_file);
        let path = Path::new(path_str);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        Some(File::create(&path).expect(format!("failed to create file {}", cmd_file).as_str()))
    }
}

struct Options<'a> {
    base_dir: &'a str,
    artifact_dir: &'a str,
    skip_sudo: bool,
    log_home: &'a str,
    config_home: &'a str,
    data_dir: &'a str,
    cassandra_pid: &'a str,
    prometheus_jar: &'a str,
    jmx_port: &'a str,
    jmx_username: &'a str,
    jmx_password: &'a str,
    nodetool_host: &'a str,
    nodetool_credentials: &'a str,
    cqlsh_host: &'a str,
    cqlsh_opts: &'a str,
    cqlsh_password: &'a str,
    timeout_opts: &'a str,
    dse_bin_dir: &'a str,
    dt_opts: &'a str,
    solr_data_dir: &'a str,
}

struct Cmd<'a> {
    command: &'a str,
    args: &'a str,
    file: &'a str,
    optional: bool,
    skip_flags: &'a str,
    use_stdout: bool,
    use_sudo: bool,
    use_timeout: bool,
}

const COMMANDS: &[Cmd<'static>] = &[
    // cqlsh "$(hostname)" $cqlshOpts -e 'DESCRIBE SCHEMA;' > "$artifactDir/schema.cql"
    Cmd {
        command: "cqlsh",
        args: "{cqlsh_host} {cqlsh_opts} -f {artifact_dir}/execute_schema.cql",
        file: "schema.cql",
        optional: false,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cqlsh "$(hostname)" $cqlshOpts -e 'DESCRIBE CLUSTER;' > "$artifactDir/metadata.cql"
    Cmd {
        command: "cqlsh",
        args: "{cqlsh_host} {cqlsh_opts} -f {artifact_dir}/execute_metadata.cql",
        file: "driver/metadata.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // "java -cp $baseDir/$prometheus io.prometheus.jmx.JmxScraper service:jmx:rmi:///jndi/rmi://127.0.0.1:$jmxPort/jmxrmi $jmxUsername $jmxPassword  > $artifactDir/metrics.jmx"
    Cmd {
        command: "java",
        args: "-cp {prometheus_jar} io.prometheus.jmx.JmxScraper service:jmx:rmi:///jndi/rmi://127.0.0.1:{jmx_port}/jmxrmi {jmx_username} {jmx_password}",
        file: "metrics.jmx",
        optional: false,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // uname -a > os/uname.txt
    Cmd {
        command: "uname",
        args: "-a",
        file: "os/uname.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // sar -B > os/sar.txt
    Cmd {
        command: "sar",
        args: "-B",
        file: "os/sar.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // lsblk > os/lsblk.txt
    Cmd {
        command: "lsblk",
        args: "",
        file: "os/lsblk.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // lsblk -oname,kname,fstype,mountpoint,label,ra,model,size,rota  >  os/lsblk_custom.txt
    Cmd {
        command: "lsblk",
        args: "-oname,kname,fstype,mountpoint,label,ra,model,size,rota",
        file: "os/lsblk_custom.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // lspci > os/lspci.txt
    Cmd {
        command: "lspci",
        args: "",
        file: "os/lspci.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // hostname -f > os/hostname.txt
    Cmd {
        command: "hostname",
        args: "-f",
        file: "os/hostname.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  ps auxww > os/ps-aux.txt
    Cmd {
        command: "ps",
        args: "auxww",
        file: "os/ps-aux.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  uptime > os/uptime.txt
    Cmd {
        command: "uptime",
        args: "",
        file: "os/uptime.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  date > os/date.txt
    Cmd {
        command: "date",
        args: "",
        file: "os/date.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  ifconfig > os/ifconfig.txt
    Cmd {
        command: "ifconfig",
        args: "",
        file: "os/ifconfig.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  lscpu >  os/lscpu.txt
    Cmd {
        command: "lscpu",
        args: "",
        file: "os/lscpu.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  ss -at > os/ss.txt
    Cmd {
        command: "ss",
        args: "-at",
        file: "os/ss.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  top -n 10 -b -d 1 > os/top.txt
    Cmd {
        command: "top",
        args: "-n 10 -b -d 1",
        file: "os/top.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //    vmstat 2 30 > "os/vmstat.txt
    Cmd {
        command: "vmstat",
        args: "2 30",
        file: "os/vmstat.txt",
        optional: true,
        skip_flags: "skipStat",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  env > os/env.txt
    Cmd {
        command: "env",
        args: "",
        file: "os/env.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  java -version > os/java-version.txt 2>&1
    Cmd {
        command: "java",
        args: "-version",
        file: "os/java-version.txt",
        optional: false,
        skip_flags: "",
        use_stdout: false,
        use_sudo: false,
        use_timeout: false,
    },
    //    sudo -l > os/sudo-l.txt
    Cmd {
        command: "sudo",
        args: "-l",
        file: "os/sudo-l.txt",
        optional: true,
        skip_flags: "skipSudo",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  cat /sys/kernel/mm/transparent_hugepage/enabled > os/transparent_hugepage-enabled.txt
    Cmd {
        command: "cat",
        args: "/sys/kernel/mm/transparent_hugepage/enabled",
        file: "os/transparent_hugepage-enabled.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  cat /sys/kernel/mm/transparent_hugepage/defrag > os/transparent_hugepage-defrag.txt
    Cmd {
        command: "cat",
        args: "/sys/kernel/mm/transparent_hugepage/defrag",
        file: "os/transparent_hugepage-defrag.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    //  numactl --hardware > os/numactl-hardware.txt
    Cmd {
        command: "numactl",
        args: "--hardware",
        file: "os/numactl-hardware.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cp -r /proc/cpuinfo /proc/meminfo /proc/interrupts /proc/version /etc/fstab /etc/security/limits.conf $artifactSubDir/
    Cmd {
        command: "cp",
        args: "-r /proc/cpuinfo /proc/meminfo /proc/interrupts /proc/version /etc/fstab /etc/security/limits.conf {artifact_dir}/os/",
        file: "",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cp -r /etc/security/limits.d/* $artifactSubDir/limits.d/.
    Cmd {
        command: "cp",
        args: "-r /etc/security/limits.d {artifact_dir}/os/",
        file: "",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cat /etc/*-release > $artifactSubDir/os.txt
    // use find as we can't use shell globs
    Cmd {
        command: "find",
        args: "/etc/ -name *-release -exec cat {} +",
        file: "os/os.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // curl http://169.254.169.254/latest/meta-data/instance-type > $artifactSubDir/instance_type.txt
    Cmd {
        command: "curl",
        args: "--connect-timeout 10 -s http://169.254.169.254/latest/meta-data/instance-type",
        file: "cloud/instance_type.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // curl http://169.254.169.254/latest/meta-data/placement/availability-zone "$artifactSubDir/az_info.txt"
    Cmd {
        command: "curl",
        args: "--connect-timeout 10 -s http://169.254.169.254/latest/meta-data/placement/availability-zone",
        file: "cloud/az_info.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // "ec2metadata" > "$artifactDir/cloud/aws-metadata.txt
    Cmd {
        command: "ec2metadata",
        args: "",
        file: "cloud/aws-metadata.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // curl --connect-timeout 10 http://metadata.google.internal/computeMetadata/v1/instance/ > $artifactDir/$sub_dir/google.txt
    Cmd {
        command: "curl",
        args: "--connect-timeout 10 -s http://metadata.google.internal/computeMetadata/v1/instance/",
        file: "cloud/google.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // slabtop -o -s c > $artifactDir/os/slaptop.txt
    Cmd {
        command: "slabtop",
        args: "-o -s c",
        file: "os/slaptop.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // sysctl -a > $artifactDir/os/sysctl.txt
    Cmd {
        command: "sysctl",
        args: "-a",
        file: "os/sysctl.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // blockdev --report > $artifactDir/os/blockdev-report.txt
    Cmd {
        command: "blockdev",
        args: "--report",
        file: "os/blockdev-report.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // lsof -i -P | grep cassandra > $artifactDir/os/lsof-cassandra.txt
    Cmd {
        command: "lsof",
        args: "-i -P", // TODO `| grep cassandra`
        file: "os/lsof-cassandra.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // netstat -nr > $artifactDir/os/netstat-nr.txt
    Cmd {
        command: "netstat",
        args: "-nr",
        file: "os/netstat-nr.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // netstat -lptu > $artifactDir/os/netstat-lptu.txt
    Cmd {
        command: "netstat",
        args: "-lptu",
        file: "os/netstat-lptu.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // netstat -tulpn > $artifactDir/os/netstat-tulpn.txt
    Cmd {
        command: "netstat",
        args: "-tulpn",
        file: "os/netstat-tulpn.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // cp -r $logHome/* $artifactSubDir/.
    Cmd {
        command: "cp",
        args: "-R -L {log_home} {artifact_dir}/logs",
        file: "",
        optional: false,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cp -r $configHome/* $artifactSubDir/.
    Cmd {
        command: "cp",
        args: "-R -L {config_home} {artifact_dir}/conf",
        file: "",
        optional: false,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // netstat --statistics > $artifactSubDir/netstat-summary.txt
    Cmd {
        command: "netstat",
        args: "--statistics",
        file: "network/netstat-summary.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // ntpstat > $artifactSubDir/ntpstat.txt
    Cmd {
        command: "ntpstat",
        args: "",
        file: "network/ntpstat.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // ntpq -p > $artifactSubDir/ntpq-p.txt
    Cmd {
        command: "ntpq",
        args: "-p",
        file: "network/ntpq-p.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // ifconfig > $artifactSubDir/ifconfig.txt
    Cmd {
        command: "ifconfig",
        args: "",
        file: "network/ifconfig.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // df -h > $artifactSubDir/df-size.txt
    Cmd {
        command: "df",
        args: "-h",
        file: "storage/df-size.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // df -i > $artifactSubDir/df-inode.txt
    Cmd {
        command: "df",
        args: "-i",
        file: "storage/df-inode.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // iostat -dmx 5 24 > $artifactSubDir/iostat-dmx.txt
    Cmd {
        command: "iostat",
        args: "-dmx 5 24 ",
        file: "storage/iostat-dmx.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // dstat -am  --output $artifactSubDir/dstat.txt 1 60
    Cmd {
        command: "{base_dir}/dstat",
        args: "-am --output {artifact_dir}/storage/dstat.txt 1 60",
        file: "",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // pvdisplay > $artifactSubDir/pvdisplay.txt
    Cmd {
        command: "pvdisplay",
        args: "",
        file: "storage/pvdisplay.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // vgdisplay > $artifactSubDir/vgdisplay.txt
    Cmd {
        command: "vgdisplay",
        args: "",
        file: "storage/vgdisplay.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // lvdisplay -a > $artifactSubDir/lvdisplay.txt
    Cmd {
        command: "lvdisplay",
        args: "-a",
        file: "storage/lvdisplay.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // lvs -a > $artifactSubDir/lvs.txt
    Cmd {
        command: "lvs",
        args: "-a",
        file: "storage/lvs.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // jcmd $cassandra_pid VM.system_properties > java_system_properties.txt
    Cmd {
        command: "jcmd",
        args: "{cassandra_pid} VM.system_properties",
        file: "java_system_properties.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // jcmd $cassandra_pid VM.command_line > java_command_line.txt
    Cmd {
        command: "jcmd",
        args: "{cassandra_pid} VM.command_line",
        file: "java_command_line.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // nodetool $nodetoolHost -p $jmxPort $nodetoolCredentials $nodetoolCmd > "$artifactSubDir/$nodetoolCmd.txt"
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} status",
        file: "nodetool/status.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} tpstats",
        file: "nodetool/tpstats.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} cfstats",
        file: "nodetool/cfstats.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} info",
        file: "nodetool/info.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} ring",
        file: "nodetool/ring.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} version",
        file: "nodetool/version.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} proxyhistograms",
        file: "nodetool/proxyhistograms.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} compactionstats",
        file: "nodetool/compactionstats.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} describecluster",
        file: "nodetool/describecluster.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} getcompactionthroughput",
        file: "nodetool/getcompactionthroughput.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} getstreamthroughput",
        file: "nodetool/getstreamthroughput.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} gossipinfo",
        file: "nodetool/gossipinfo.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} netstats",
        file: "nodetool/netstats.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} statusbinary",
        file: "nodetool/statusbinary.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    Cmd {
        command: "nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} statusthrift",
        file: "nodetool/statusthrift.txt",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // collect all the sstable -Statistics.db' files
    Cmd {
        command: "find",
        args: "{data_dir} -maxdepth 3 -name *-Statistics.db -exec cp --parents {} {artifact_dir}/sstable-statistics/ ;",
        file: "",
        optional: true,
        skip_flags: "",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },

    // DSE //

    // cp "$configHome/dse.yaml" "$artifactDir/conf/dse/"
    // use cat so to lazy create destination directory
    Cmd {
        command: "cat",
        args: "{config_home}/dse.yaml",
        file: "conf/dse/dse.yaml",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // cp "/etc/default/dse" "$artifactDir/conf/dse/"
    Cmd {
        command: "cp",
        args: "-R -L /etc/default/dse {artifact_dir}/conf/dse/",
        file: "",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: false,
    },
    // cp "$logHome/audit/dropped-events.log" "$artifactDir/logs/cassandra/audit"
    // use cat so to lazy create destination directory
    Cmd {
        command: "cat",
        args: "{log_home}/audit/dropped-events.log {artifact_dir}/",
        file: "logs/cassandra/audit/dropped-events.log",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: true,
        use_timeout: false,
    },
    // $dse_bin_dir/dsetool $dt_opts status > "$artifactDir/dsetool/status"
    Cmd {
        command: "{dse_bin_dir}dsetool",
        args: "{dt_opts} status",
        file: "dsetool/status.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // $dse_bin_dir/dsetool $dt_opts ring > "$artifactDir/dsetool/ring"
    Cmd {
        command: "{dse_bin_dir}dsetool",
        args: "{dt_opts} ring",
        file: "dsetool/ring.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // $dse_bin_dir/dsetool $dt_opts insights_config --show_config > "$artifactDir/dsetool/insights_config"
    Cmd {
        command: "{dse_bin_dir}dsetool",
        args: "{dt_opts} insights_config --show_config",
        file: "dsetool/insights_config.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // $dse_bin_dir/dsetool $dt_opts insights_filters --show_filters > "$artifactDir/dsetool/insights_filters"
    Cmd {
        command: "{dse_bin_dir}dsetool",
        args: "{dt_opts} insights_filters --show_filters",
        file: "dsetool/insights_filters.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // $dse_bin_dir/dsetool $dt_opts perf cqlslowlog recent_slowest_queries > "$artifactDir/dsetool/slowest_queries"
    Cmd {
        command: "{dse_bin_dir}dsetool",
        args: "{dt_opts} perf cqlslowlog recent_slowest_queries",
        file: "dsetool/slowest_queries.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // $dse_bin_dir/nodetool $nodetoolHost -p $jmxPort $nodetoolCredentials nodesyncservice getrate > "$artifactDir/nodetool/nodesyncrate"
    Cmd {
        command: "{dse_bin_dir}nodetool",
        args: "{nodetool_host} -p {jmx_port} {nodetool_credentials} nodesyncservice getrate",
        file: "nodetool/nodesyncrate.txt",
        optional: true,
        skip_flags: "skip_dse no_nodesyncrate",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
    // cd "$solr_data_dir" && du -s -- *
    Cmd {
        command: "du",
        args: "-s -- {solr_data_dir}/",
        file: "solr/cores-sizes.txt",
        optional: true,
        skip_flags: "skip_dse",
        use_stdout: true,
        use_sudo: false,
        use_timeout: true,
    },
];
