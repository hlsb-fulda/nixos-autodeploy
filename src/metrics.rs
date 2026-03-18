use crate::{
    RUN_BOOTED_SYSTEM, RUN_CURRENT_SYSTEM, RUN_DEPLOYED_SYSTEM, RUN_UPSTREAM_SYSTEM, resolve,
};
use color_eyre::Result;
use color_eyre::eyre::Context;
use prometheus::proto::{Gauge, LabelPair, Metric, MetricFamily, MetricType};
use prometheus::{Encoder, TextEncoder};
use std::path::Path;

#[derive(Default)]
pub struct State {
    // The dirty state tracks, if the system has been deployed manually and differs from upstream,
    // thus preventing automatic deployments
    pub dirty: bool,

    // Track if the system needs a reboot for full update
    pub reboot_pending: bool,
}

impl State {
    pub fn write_metrics(self, path: &Path) -> Result<()> {
        fn generation_label(name: &str, path: impl AsRef<Path>) -> Result<Option<LabelPair>> {
            let Some(path) = resolve(path)? else {
                return Ok(None);
            };

            let value = path
                .file_name()
                .expect("resolved symlink returns absolute path");
            let value = value.display().to_string();

            Ok(Some(LabelPair {
                name: Some(format!("{name}_generation")),
                value: Some(value),
                ..Default::default()
            }))
        }

        let current_gen = generation_label("current", RUN_CURRENT_SYSTEM)?;
        let booted_gen = generation_label("booted", RUN_BOOTED_SYSTEM)?;
        let deployed_gen = generation_label("deployed", RUN_DEPLOYED_SYSTEM)?;
        let upstream_gen = generation_label("upstream", RUN_UPSTREAM_SYSTEM)?;

        std::fs::create_dir_all(path.parent().expect("must have parent"))?;

        let metric_info = MetricFamily {
            name: Some("nixos_autodeploy_info".to_string()),
            help: Some("info about the current generations".to_string()),
            type_: Some(MetricType::GAUGE.into()),
            metric: vec![Metric {
                label: [current_gen, booted_gen, deployed_gen, upstream_gen]
                    .into_iter()
                    .flatten()
                    .collect(),
                gauge: Gauge {
                    value: Some(1f64),
                    ..Default::default()
                }
                .into(),
                timestamp_ms: None,
                ..Default::default()
            }],
            ..Default::default()
        };

        let metric_dirty = MetricFamily {
            name: Some("nixos_autodeploy_dirty".to_string()),
            help: Some("1 if system is not tracking upstream".to_string()),
            type_: Some(MetricType::GAUGE.into()),
            metric: vec![Metric {
                gauge: Gauge {
                    value: Some(self.dirty as u8 as f64),
                    ..Default::default()
                }
                .into(),
                timestamp_ms: None,
                ..Default::default()
            }],
            ..Default::default()
        };

        let metric_reboot_required = MetricFamily {
            name: Some("nixos_autodeploy_reboot_required".to_string()),
            help: Some("1 if system needs to be restarted for full update".to_string()),
            type_: Some(MetricType::GAUGE.into()),
            metric: vec![Metric {
                gauge: Gauge {
                    value: Some(self.reboot_pending as u8 as f64),
                    ..Default::default()
                }
                .into(),
                timestamp_ms: None,
                ..Default::default()
            }],
            ..Default::default()
        };

        let mut buffer = Vec::new();
        TextEncoder::new().encode(
            &[metric_dirty, metric_reboot_required, metric_info],
            &mut buffer,
        )?;

        std::fs::write(path, &buffer).with_context(|| {
            format!(
                "Failed to write prometheus metrics: {path}",
                path = path.display()
            )
        })?;

        Ok(())
    }
}
