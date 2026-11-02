//! Background bridge to the shared Python regression evaluator. UART stays responsive.
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

pub struct RegressionService {
    root: PathBuf,
    tuning: Value,
    worker: Option<Receiver<Value>>,
    status: Value,
}

impl RegressionService {
    pub fn new(root: PathBuf, tuning: Value) -> Self {
        Self { root, tuning, worker: None, status: json!({"type":"regression_status","state":"idle"}) }
    }

    pub fn running(&mut self) -> bool {
        self.refresh();
        self.worker.is_some()
    }

    pub fn poll(&mut self) -> Value {
        self.refresh();
        self.status.clone()
    }

    fn refresh(&mut self) {
        if let Some(receiver) = &self.worker {
            match receiver.try_recv() {
                Ok(result) => {
                    self.status["state"] = json!("complete");
                    self.status["result"] = result;
                    self.worker = None;
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.status["state"] = json!("complete");
                    self.status["result"] = json!({"type":"regression_error","message":"Regression worker stopped. Try again."});
                    self.worker = None;
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
    }

    pub fn start(&mut self, request: &Value) -> io::Result<Value> {
        if self.running() { return Err(io::Error::other("A regression tool task is already running; wait for it to finish")); }
        let tool = std::env::var_os("RADAR_REGRESSION_TOOL").map(PathBuf::from)
            .unwrap_or_else(||PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tools/shot_regression_service.py"));
        if !tool.is_file() { return Err(io::Error::other("The regression worker is missing on the radar computer. Install tools/shot_regression_service.py and shot_regression.py beside radar_app, or set RADAR_REGRESSION_TOOL.")); }
        let envelope = json!({"root":self.root,"binary":std::env::current_exe()?,"tuning":self.tuning,"request":request});
        let job = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos().to_string();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result = (|| -> io::Result<Value> {
                let python = std::env::var_os("RADAR_PYTHON").unwrap_or_else(||if cfg!(windows) {"python".into()} else {"python3".into()});
                let mut child = Command::new(python).arg(tool).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn()?;
                serde_json::to_writer(child.stdin.as_mut().unwrap(), &envelope)?;
                child.stdin.take().unwrap().flush()?;
                let output = child.wait_with_output()?;
                if !output.status.success() { return Err(io::Error::other("Regression worker failed. Check the radar service's console.")); }
                if output.stdout.len() > 1500 * 1024 { return Err(io::Error::other("Regression response is too large; use a smaller recording collection.")); }
                Ok(serde_json::from_slice(&output.stdout)?)
            })();
            let response = result.unwrap_or_else(|error|json!({"type":"regression_error","message":format!("Cannot run regression tool: {error}. Python 3 is required on the radar computer.")}));
            let _ = sender.send(response);
        });
        self.worker = Some(receiver);
        self.status = json!({"type":"regression_status","state":"running","job_id":job,"operation":request["type"],"request_id":request["request_id"]});
        Ok(self.status.clone())
    }
}
