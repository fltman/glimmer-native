# A learned model for removing objects: research, parked

Status 2026-11-16: **parked**. No model work, no search for alternatives, nothing downloaded, until Anders says so. It comes down to one question for a lawyer (below). The classic fill that needs no model is Heal Selection (`PATENTS.md`).

Not legal advice. Everything quoted here was fetched and read on 2026-11-16 unless it says otherwise. No weights were downloaded and nothing was added to the repository.

## The short version

- Apple has no public API for inpainting or object removal (Core Image, Vision, PhotoKit, MPS, vImage) through macOS 27. Clean Up exists only in the Photos app. Apple gives the mask (`GenerateForegroundInstanceMaskRequest`; on 27 `GenerateIterativeSegmentationRequest`), not the fill. (Found 2026-11-15 through a summarising tool; not re-read.)
- Two models pass the licence rules on their face: **MI-GAN** (about 15 MB, explicit MIT grant for the weights) and **LaMa** (about 190 MB, Apache-2.0 repository, no statement about the weights). MAT and DeepFill v2 are out (CC BY-NC 4.0, as found 2026-11-15).
- Both were trained on **Places2**, whose terms the downloader accepted are "non-commercial research and educational purposes". Whether that reaches someone who ships the trained weights is the open question, and only a lawyer or MIT can close it.
- On a plain reading of the independent claims of the network patents found, running either model matches none of them. One reading deserves a lawyer's confirmation (Nvidia, "partial convolution").
- If this goes further: MI-GAN before LaMa, and the one question to a lawyer is "may weights trained by a third party on Places2 be shipped in a commercial app".

## Could not be opened

- USPTO Patent Center and the USPTO maintenance-fee lookup (403); the USPTO API wants a key. Expiry was read from the Official Gazette instead (`PATENTS.md`).
- The browser extension was not connected, so nothing that needs a real browser was read.
- Patent claims were read on Google Patents, not on USPTO full text. Only the patents already on the list were read; no new search. Dependent claims were not analysed. Several families show pending members that can issue with different claims.
- The Places request form's text was read; it was not submitted. The dataset's development kit README was not read.

## Places2: the terms

- `places2.csail.mit.edu/download.html` offered no image data on 2026-11-16. It says: "We are actively working on the version 2 of Places Database. If you need to use the legacy dataset (the original Places365 or Places205) urgently for research purposes, please sign this form". The form says: "All the images belong to the image owners and can only be used for research purpose. The version 1 of the Places (Places365) is provided as an archive and legacy purposes, it can only be used to reproduce and compare the algorithms."
- The earlier download page is still on the server (`places2.csail.mit.edu/download-private.html`) and ends: "Terms of use: by downloading the image data you agree to the following terms: You will use the data only for non-commercial research and educational purposes. You will NOT distribute the above images. Massachusetts Institute of Technology makes no representations or warranties regarding the data, including but not limited to warranties of non-infringement or fitness for a particular purpose."
- MIT's own models trained on it are licensed differently (`github.com/CSAILVision/places365`, README): "The pretrained places-CNN models can be used under the Creative Common License (Attribution CC BY). Please give appropriate credit, such as providing a link to our paper or to the Places Project Page. The copyright of all the images belongs to the image owners."

Plain reading: the terms are a promise by whoever downloaded the images (Samsung, Picsart). They say nothing either way about models trained on the images. MIT licensing its own trained models CC BY shows that MIT does not treat a trained model as "the data", but that is MIT's choice for MIT's models, not a grant to others.

## What the repositories say about the weights

**LaMa** (`github.com/advimman/lama`):

- `LICENSE` is Apache-2.0 and ends "Copyright [2021] Samsung Research".
- The README does not contain the string "licen" at all: there is no statement about the weights.
- The weights are not in the repository. The README says "The best model (Places2, Places Challenge): curl -LJO https://huggingface.co/smartywu/big-lama/resolve/main/big-lama.zip" and "All models (Places & CelebA-HQ)" in a Google Drive folder. The Hugging Face account is a third party's; its metadata tag `license:apache-2.0` was set by that account, not by Samsung. "big-lama is Apache-2.0" is therefore an inference from the repository's licence.
- `configs/training/big-lama.yaml`: generator `ffc_resnet` with `input_nc: 4` (image and mask), one discriminator, `pix2pixhd_nlayer`.

**MI-GAN** (`github.com/Picsart-AI-Research/MI-GAN`):

- README: "Download pre-trained MI-GAN models from here (see LICENSE-WEIGHTS for the license)". `LICENSE-WEIGHTS` is the MIT licence, "Copyright (c) 2024 Picsart AI Research (PAIR)", word for word the same as `LICENSE`. That is an explicit grant for the weights from the people who trained them.
- The repository also carries NVIDIA files. `torch_utils/misc.py` begins: "Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved. [...] Any use, reproduction, disclosure or distribution of this software and related documentation without an express license agreement from NVIDIA CORPORATION is strictly prohibited." So the repository's code is not uniformly MIT. `lib/model_zoo/migan_inference.py` has no such header and imports only numpy and torch; only that file would be a basis for a port.
- The Places2 model is distilled from a Co-Mod-GAN teacher trained on Places2 (README, training section), so the Places2 question applies to MI-GAN as much as to LaMa.

## The network patents: independent claims and a plain reading

"Running LaMa or MI-GAN" means: one feed-forward generator, image and mask in, image out; ordinary convolutions (LaMa: also Fourier convolutions); no discriminator exists at inference. LaMa's architecture is from its config above. MI-GAN's is from memory of the paper, not re-read on 2026-11-16.

| Patent | What an independent claim requires (quoted) | Reading |
|---|---|---|
| Nvidia US 12,425,605 (active; no expiry shown) | Claim 1: "performing, using a neural network, two or more successive partial convolutions using corresponding masks to generate two or more feature maps that successively increase a number of valid pixels used in each respective partial convolution to at least partially fill one or more holes in one or more images." Claims 8 and 15: the same as a system and a processor. | Needs partial convolutions whose masks grow layer by layer. Both models feed the mask as an input channel to ordinary convolutions. Absent. **Worth a lawyer's confirmation**: "partial convolution" would be construed from the specification, which was not read in full. |
| Adobe US 10,614,557 (to 2038) | Claim 1: "an image completer having a framework that combines generative and discriminative neural networks using adversarial deep learning, [...] the discriminative neural networks including a local discriminator network and a global discriminator network; [...] the image completer outputting the filled digital image based on iterations of: generating proposed hole-filling digital content with the generative neural network [...]; and determining with the discriminative neural networks whether the proposed hole-filling digital content is computer-generated". Claims 14 and 18 also require the local and the global discriminator. | What would ship has no discriminator, and LaMa was trained with one patch discriminator, not a global and local pair. Absent. MI-GAN's training setup was not verified from a primary source. |
| Adobe US 11,250,548 (to 2038) | All three independent claims are training claims: "a method [...] to train an image completion framework [...] adjusting parameters of the generative neural network or the global and local discriminative neural networks". | Glimmer would not train. Not matched by inference. |
| Adobe US 10,755,391 (to 2038) | Claim 1: "a dual-stage image completion framework that combines a coarse image neural network and an image refinement neural network [...] refining the coarse prediction by copying information corresponding to patches of pixels included in the depicted imagery of the holey image based on a measure of similarity". | Needs a coarse result and then a network that copies patches by similarity. Both models are single-stage with no patch copying. Absent. |
| Adobe US 11,334,971 (to 2038) | Claim 1: as '391, shorter, adding "trained based on generative adversarial network (GAN) losses". Claim 16: "refining the coarse prediction of the imagery using a neural network that performs a patch-matching technique that includes copying one or more patches of pixels of depicted imagery of the digital image based on a measure of similarity with the coarse prediction". | Absent, with the two cautions below. |
| Samsung US 12,293,487 (to 2043) | Claim 1 requires "structure vectors [...] each structure vector including one or more lines and one or more junctions" from a first model, fed to a second. | Absent. |
| Google US 11,854,120 | Claim 1 requires "determining a palette transform based a comparison of the first image and the inpainted image" and recolouring with it. | Absent. |
| Google US 12,217,472 (to 2043) | The claims are about a segmentation model trained with augmented "broken powerlines". | Absent; Glimmer would use the user's selection. |

## Two things to keep out, if a model is ever used

1. **LaMa's refinement pass** (`refine=True`). It is an optimisation loop rather than patch copying, but it is a second stage after a first result. Leave it off.
2. **Running the exemplar fill on top of a network's result.** A coarse network fill refined by copying similar patches from the image is much closer to Adobe US 11,334,971 claim 16 than either part is alone. Heal Selection and a model must stay two separate tools, never a pipeline.

## Open, for whoever picks this up

- The lawyer question about Places2 (above).
- Confirmation of the Nvidia reading.
- For LaMa: a statement from Samsung about the weights, or do without LaMa.
- A model not trained on Places2 would go around the question rather than through it. Not looked for; parked with the rest.
