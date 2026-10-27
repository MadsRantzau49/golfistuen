use std::io::{Read, Write};

pub fn record<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    buffer: &mut [u8],
) -> std::io::Result<usize> {
    let bytes_read = reader.read(buffer)?;

    if bytes_read > 0 {
        writer.write_all(&buffer[..bytes_read])?;
    }

    Ok(bytes_read)
}
