use crate::transport::serial::connect;
use serialport::SerialPort;
use std::io::{Read, Write};
use std::time::{Duration, Instant};

pub struct RadarDevice {
    cli: Box<dyn SerialPort>,
    data: Box<dyn SerialPort>,
}

impl RadarDevice {
    pub fn new(
        cli_path: &str,
        cli_baud: u32,
        data_path: &str,
        data_baud: u32,
    ) -> Result<Self, serialport::Error> {
        let cli = connect(cli_path, cli_baud)?;
        let data = connect(data_path, data_baud)?;

        Ok(Self { cli, data })
    }

    pub fn send_command(&mut self, command: &str) -> std::io::Result<()> {
        let command_string = format!("{command}\n");
        let byte_command = command_string.as_bytes();

        self.cli.write_all(byte_command)?;

        let mut buffer = [0u8; 256];
        let mut response = String::new();

        let start = Instant::now();
        let timeout = Duration::from_secs(5);

        loop {
            if start.elapsed() >= timeout {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    format!("Radar response timeout: {response}"),
                ));
            }
            match self.cli.read(&mut buffer) {
                Ok(number_of_bytes) if number_of_bytes > 0 => {
                    let received = String::from_utf8_lossy(&buffer[..number_of_bytes]);
                    response.push_str(&received);
                    if response.contains("mmwDemo:/>") {
                        if response
                            .lines()
                            .any(|line| line.trim_start().starts_with("Error"))
                        {
                            return Err(std::io::Error::other(format!(
                                "Radar Rejected command: {response}"
                            )));
                        }
                        if response.lines().any(|line| line.trim() == "Done") {
                            eprintln!("\n{response}\n");
                            return Ok(());
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    continue;
                }

                Err(e) => return Err(e),

                _ => {}
            }
        }
    }

    pub fn upload_config(&mut self, commands: &[String]) -> std::io::Result<()> {
        if commands.is_empty() {
            return Err(std::io::Error::other("Configuration is empty"));
        }

        self.send_command("sensorStop")?;
        self.send_command("flushCfg")?;

        for command in commands {
            let command_name = command.split_whitespace().next().unwrap_or("");

            match command_name {
                "sensorStop" | "flushCfg" | "sensorStart" => {
                    continue;
                }

                _ => {
                    self.send_command(command)?;
                }
            }
        }

        self.send_command("sensorStart")?;

        Ok(())
    }

    pub fn read_data(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.data.read(buffer)
    }

    pub fn set_data_timeout(&mut self, timeout: Duration) -> Result<(), serialport::Error> {
        self.data.set_timeout(timeout)
    }
}
