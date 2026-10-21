# Third-Party Notices

This project (MIT, see [LICENSE](LICENSE)) orchestrates the third-party
software, models and services listed below. It does not redistribute them —
the deploy skill installs them into the user's Crusoe cluster, and the workload
skill pulls and executes them at pinned versions/commits. Each component's
license applies to *your* use; the notes below state where a license requires
active acceptance (the skills gate on those).

An important split for the NVIDIA components: **source code** and **model
weights** carry different licenses. Where a row says "model weights", that
license covers the checkpoints the workflow downloads, not the repository.

| Component | What this project uses | License | SPDX | Notes |
|---|---|---|---|---|
| **NVIDIA OSMO** | Helm charts `nvidia/osmo/service` + `nvidia/osmo/backend-operator` 1.3.1 (via `helm.ngc.nvidia.com`); `nvcr.io/nvidia/osmo/*` container images | [Apache-2.0](https://github.com/NVIDIA/OSMO/blob/main/LICENSE) | Apache-2.0 | Pulling and using the NGC-hosted charts/images additionally accepts NGC's artifact terms ("By pulling and using NVIDIA OSMO artifacts, you accept the terms and conditions of the License") |
| **Cosmos-Predict2** | Repository checkout `661da47`; NGC container `nvcr.io/nvidia/cosmos/cosmos-predict2-container:1.2`; model checkpoints downloaded in stage 2a | Source: [Apache-2.0](https://github.com/nvidia-cosmos/cosmos-predict2/blob/main/LICENSE); model weights: [NVIDIA Open Model License](https://huggingface.co/nvidia) (e.g. `nvidia/Cosmos-Predict2-14B-Video2World`) | Apache-2.0 (code) | The stage-2a task downloads the 480p/10fps Video2World checkpoint, whose HF page states the NVIDIA Open Model License |
| **Isaac GR00T** | Repository checkout `796ca8d8` (stage 1 modality/converter pin `d2b7e75b`); base model `nvidia/GR00T-N1.5-3B` for stage-3 fine-tuning | Source: [Apache-2.0](https://github.com/NVIDIA/Isaac-GR00T/blob/main/LICENSE); model weights: NVIDIA Open Model License (`nvidia/GR00T-N1.5-3B` on Hugging Face) | Apache-2.0 (code) | **License acceptance is a hard gate** in the run skill (Phase 1d): no submit proceeds until the user has accepted the NVIDIA Open Model License for the base model on their own HF account |
| **LeRobot** | Converter subproject (LeRobot v3→v2.1 conversion) at pin `c75455a6`; dataset `izuluaga/finish_sandwich` (LeRobot v3 format) | [Apache-2.0](https://github.com/huggingface/lerobot/blob/main/LICENSE) | Apache-2.0 | The dataset carries its own terms on its Hugging Face page; the user is responsible for the license of any dataset they substitute |
| **Keycloak** | Bitnami Helm chart `bitnami/keycloak` 24.4.9; image `bitnamilegacy/keycloak` 26.1.1-debian-12-r0 | [Apache-2.0](https://github.com/keycloak/keycloak/blob/main/LICENSE.txt) (Keycloak); chart/image © Broadcom, [Apache-2.0](https://github.com/bitnami/charts) | Apache-2.0 | Installed only when the Keycloak login is enabled (deploy Phase 10, the default) |
| **Envoy** | Gateway proxy via the OSMO chart; image `envoyproxy/envoy:v1.38.1` | [Apache-2.0](https://github.com/envoyproxy/envoy/blob/main/LICENSE) | Apache-2.0 | Deployed as part of the OSMO gateway |
| **cert-manager** | Helm chart `jetstack/cert-manager` v1.21.2 (cluster add-on) | [Apache-2.0](https://github.com/cert-manager/cert-manager/blob/master/LICENSE) | Apache-2.0 | Issues the self-signed gateway/Keycloak certificates |
| **KAI Scheduler** | Helm chart `oci://ghcr.io/kai-scheduler/kai-scheduler` v0.16.1 | [Apache-2.0](https://github.com/NVIDIA/kai-scheduler/blob/main/LICENSE) | Apache-2.0 | Schedules workflow pods to the GPU pools |
| **Crusoe Load Balancer Controller** | Helm chart `crusoe-lb/crusoe-lb-controller` 0.0.24 (Private Beta product) | [Apache-2.0](https://github.com/crusoecloud/crusoe-load-balancer-controller-helm-charts) | Apache-2.0 | The chart repo is public; the controller itself is a Private Beta Crusoe product |
| **PyTorch / Python images** | `pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel` (stage 3), `python:3.10-slim` (stages 1, 4) | PyTorch: [BSD-3-Clause](https://github.com/pytorch/pytorch/blob/main/LICENSE) (+ CUDA/cuDNN under NVIDIA's cudnn/cuda toolkit terms); python: Docker images under the [Python Software Foundation License](https://docs.docker.com/legal/image-licenses/) and base-image terms | BSD-3-Clause (PyTorch) | GPU stage images bundle NVIDIA CUDA toolkit components under their own EULA |

## Trademarks

NVIDIA, OSMO, Cosmos and Isaac GR00T are trademarks of NVIDIA Corporation.
Keycloak is a trademark of the Keycloak project / Red Hat. PyTorch is a
trademark of the PyTorch Foundation (LF Projects, LLC). This project is not
affiliated with, endorsed by, or sponsored by any of them.

## Scope

This inventory covers the components these skills install, pin or execute at
the versions current when the pinned commits were made. Transitive package
dependencies (PyPI distributions installed inside workflow pods — e.g.
`boto3`, `accelerate==1.15.0`, `flash_attn==2.7.1.post4`, `pyarrow==26.0.0`,
`uv` 0.13.2) each carry their own license, reproduced on their PyPI/HF pages;
the exact-pin policy in the workflows exists partly so that this list remains
checkable. The Hugging Face and NGC accounts used to pull gated content are
the user's own, and acceptance of any click-through terms happens there, on
their credentials — never by this project on the user's behalf.
