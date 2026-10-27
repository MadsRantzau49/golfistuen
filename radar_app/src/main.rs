
fn main() {
    let mut command = serialport::new("/dev/ttyUSB0", 115200).open().expect("Failed to open port");
    println!("Serial connection opened!");

}
