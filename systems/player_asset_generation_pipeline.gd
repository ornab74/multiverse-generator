extends RefCounted
class_name PlayerAssetGenerationPipeline

## Deterministic, fail-closed orchestration for player-authored asset generation.
##
## This class is deliberately an interface simulation. It does not load models,
## execute worker code, contact peers, add bytes to IPFS, sign transactions, or
## publish to a chain. It only produces bounded manifests and verifies receipts
## supplied at separately audited boundaries.

enum JobState {
	DRAFT,
	REVIEW,
	APPROVED,
	PARTITIONED,
	COMPLETED,
	PUBLISHED,
}

const SCHEMA_VERSION := "nexus.player-asset-generation/1"
const INTERFACE_MODE := "LOCAL_INTERFACE_SIMULATION_ONLY"
const DOMAIN_SEPARATOR := "NEXUS_PLAYER_ASSET_GENERATION_V1"
const MAX_PROMPT_BYTES := 12 * 1024
const MAX_PROMPT_LINES := 96
const MAX_TOTAL_CONTRIBUTION_TOKENS := 8_000_000
const MAX_MEMBER_CONTRIBUTION_TOKENS := 2_000_000
const MIN_TOTAL_CONTRIBUTION_TOKENS := 128
const MIN_OFFER_RAM_MB := 256
const MAX_OFFER_RAM_MB := 4 * 1024 * 1024
const MAX_JOB_RAM_MB := 256 * 1024 * 1024
const MAX_PARTITIONS := 4096
const MAX_PARALLEL_PARTITIONS := 64
const MAX_ADVISORY_STAKE_UNITS := 1_000_000_000_000
const MAX_ADVISORY_MEMBER_BASIS_POINTS := 3500

const MODALITIES: Array[String] = [
	"audio",
	"image",
	"model",
	"voice_to_text",
	"world",
]

const CAPABILITY_LABELS: Array[String] = [
	"audio.synthesis",
	"cpu.general",
	"geometry.model",
	"gpu.compute",
	"memory.large",
	"speech.transcription",
	"vision.image",
	"world.geometry",
]

const MODALITY_CAPABILITY := {
	"audio": "audio.synthesis",
	"image": "vision.image",
	"model": "geometry.model",
	"voice_to_text": "speech.transcription",
	"world": "world.geometry",
}

const PROMPT_FIELDS := {
	"accessibility": true,
	"art_direction": true,
	"continuity": true,
	"gameplay_constraints": true,
	"intent": true,
	"locale": true,
	"negative_constraints": true,
	"style_tags": true,
}

const PROMPT_LIMITS := {
	"accessibility": 900,
	"art_direction": 2400,
	"continuity": 1600,
	"gameplay_constraints": 2400,
	"intent": 2400,
	"negative_constraints": 1600,
}

const JOB_FIELDS := {
	"asset_name": true,
	"author_id": true,
	"contribution_budgets": true,
	"estimated_ram_mb": true,
	"governance_binding": true,
	"job_id": true,
	"lobby_id": true,
	"modality": true,
	"model_policy": true,
	"output_spec": true,
	"partition_ram_mb": true,
	"prompt": true,
	"provenance": true,
	"required_capabilities": true,
	"seed": true,
}

const GOVERNANCE_BINDING_FIELDS := {
	"consent_member_ids": true,
	"manifest_hash": true,
	"proposal_hash": true,
	"proposal_id": true,
}

const REVIEW_RECEIPT_FIELDS := {
	"authoritative": true,
	"disposition": true,
	"manifest_hash": true,
	"proposal_hash": true,
	"review_hash": true,
	"source": true,
}

const CONSENT_RECEIPT_FIELDS := {
	"approved_member_ids": true,
	"manifest_hash": true,
	"output_commitment": true,
	"proof": true,
	"proposal_hash": true,
	"receipt_hash": true,
	"required_member_ids": true,
	"review_hash": true,
	"scope": true,
	"unanimous": true,
}

const PROOF_FIELDS := {
	"algorithm": true,
	"key_id": true,
	"signature": true,
}

const MODEL_POLICY_FIELDS := {
	"allowed_modalities": true,
	"code_execution": true,
	"execution_mode": true,
	"license_id": true,
	"model_family": true,
	"model_id": true,
	"model_version": true,
	"network_access": true,
	"safety_profile": true,
	"tool_access": true,
	"training_data_declaration": true,
	"weights_commitment": true,
}

const PROVENANCE_FIELDS := {
	"created_at_bucket": true,
	"creator_member_ids": true,
	"generator_build": true,
	"license_ids": true,
	"parent_asset_cids": true,
	"source_commitments": true,
}

const CONTRIBUTION_FIELDS := {
	"member_id": true,
	"token_budget": true,
}

const OFFER_FIELDS := {
	"available_ram_mb": true,
	"capability_labels": true,
	"max_parallel_partitions": true,
	"member_id": true,
	"offer_epoch": true,
	"offer_id": true,
}

const STAKE_FIELDS := {
	"evidence_commitment": true,
	"member_id": true,
	"stake_units": true,
}

const RESULT_FIELDS := {
	"byte_size": true,
	"mime_type": true,
	"model_policy_hash": true,
	"model_receipt_hash": true,
	"offer_id": true,
	"output_hash": true,
	"prompt_commitment": true,
	"provenance_hash": true,
	"safety_review_hash": true,
	"seed": true,
}

const CAPACITY_POLICY_FIELDS := {
	"availability_basis_points": true,
	"headroom_basis_points": true,
	"replication_factor": true,
}

const FORBIDDEN_FIELD_PARTS: Array[String] = [
	"api_key",
	"api_token",
	"auth_token",
	"endpoint",
	"ip_address",
	"mnemonic",
	"password",
	"private_key",
	"raw_ip",
	"rpc_url",
	"secret_key",
	"seed_phrase",
	"signing_key",
	"socket_address",
	"webhook",
]

const INJECTION_MARKERS: Array[String] = [
	"ignore all instructions",
	"ignore previous instructions",
	"reveal the system prompt",
	"developer message",
	"system message",
	"<tool_call",
	"</tool_call",
	"function_call",
	"bypass safety",
	"override policy",
	"act as root",
	"exfiltrate",
	"call the tool",
	"use the shell",
	"run shell command",
	"execute command",
	"open a terminal",
	"bash -c",
	"powershell -command",
	"curl http",
	"wget http",
]

var _governance_proof_verifier: Callable
var _jobs: Dictionary = {}
var _offers: Dictionary = {}


func _init(governance_proof_verifier: Callable = Callable()) -> void:
	_governance_proof_verifier = governance_proof_verifier


func set_governance_proof_verifier(verifier: Callable) -> void:
	_governance_proof_verifier = verifier


func create_job(spec: Dictionary) -> Dictionary:
	var unknown := _unknown_field(spec, JOB_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_job_field_" + unknown)
	var unsafe := _unsafe_reason(spec, "job")
	if not unsafe.is_empty():
		return _failure(unsafe)

	var job_id := _clean_identifier(str(spec.get("job_id", "")), 80)
	var lobby_id := _clean_identifier(str(spec.get("lobby_id", "")), 80)
	var author_id := _clean_identifier(str(spec.get("author_id", "")), 80)
	if job_id.is_empty():
		return _failure("invalid_job_id")
	if _jobs.has(job_id):
		return _failure("duplicate_job_id")
	if lobby_id.is_empty():
		return _failure("invalid_lobby_id")
	if author_id.is_empty():
		return _failure("invalid_author_id")

	var asset_name_result := _normalize_text(str(spec.get("asset_name", "")), 120, false)
	if not asset_name_result.get("ok", false):
		return _failure("asset_name_" + str(asset_name_result.get("reason", "invalid")))
	var modality := str(spec.get("modality", "")).to_lower()
	if modality not in MODALITIES:
		return _failure("unsupported_modality")

	var governance_result := _normalize_governance_binding(spec.get("governance_binding", null))
	if not governance_result.get("ok", false):
		return governance_result
	var governance: Dictionary = governance_result["binding"]
	var consent_members: Array = governance["consent_member_ids"]
	if author_id not in consent_members:
		return _failure("author_not_in_consent_members")

	var prompt_result := _normalize_prompt(spec.get("prompt", null))
	if not prompt_result.get("ok", false):
		return prompt_result
	var output_result := _normalize_output_spec(modality, spec.get("output_spec", null))
	if not output_result.get("ok", false):
		return output_result
	var capability_result := _normalize_capabilities(spec.get("required_capabilities", null), modality)
	if not capability_result.get("ok", false):
		return capability_result
	var budget_result := _normalize_contributions(spec.get("contribution_budgets", null), consent_members)
	if not budget_result.get("ok", false):
		return budget_result
	var model_result := _normalize_model_policy(spec.get("model_policy", null), modality)
	if not model_result.get("ok", false):
		return model_result
	var provenance_result := _normalize_provenance(spec.get("provenance", null), consent_members)
	if not provenance_result.get("ok", false):
		return provenance_result

	var estimated_ram_mb := int(spec.get("estimated_ram_mb", 0))
	var partition_ram_mb := int(spec.get("partition_ram_mb", 0))
	if estimated_ram_mb < MIN_OFFER_RAM_MB or estimated_ram_mb > MAX_JOB_RAM_MB:
		return _failure("estimated_ram_mb_out_of_range")
	if partition_ram_mb < MIN_OFFER_RAM_MB or partition_ram_mb > estimated_ram_mb:
		return _failure("partition_ram_mb_out_of_range")
	var estimated_partitions := int(ceil(float(estimated_ram_mb) / float(partition_ram_mb)))
	if estimated_partitions < 1 or estimated_partitions > MAX_PARTITIONS:
		return _failure("partition_count_out_of_range")
	var seed := int(spec.get("seed", -1))
	if seed < 0 or seed > 0x7fffffff:
		return _failure("seed_out_of_range")

	var prompt: Dictionary = prompt_result["prompt"]
	var output_spec: Dictionary = output_result["output_spec"]
	var model_policy: Dictionary = model_result["model_policy"]
	var provenance: Dictionary = provenance_result["provenance"]
	var prompt_commitment := _content_commitment(prompt)
	var model_policy_hash := _content_commitment(model_policy)
	var provenance_hash := _content_commitment(provenance)
	var manifest := {
		"asset_name": asset_name_result["text"],
		"author_id": author_id,
		"contribution_budgets": budget_result["contributions"],
		"estimated_ram_mb": estimated_ram_mb,
		"governance_binding": governance,
		"interface_mode": INTERFACE_MODE,
		"job_id": job_id,
		"lobby_id": lobby_id,
		"modality": modality,
		"model_policy_hash": model_policy_hash,
		"output_spec": output_spec,
		"partition_ram_mb": partition_ram_mb,
		"prompt_commitment": prompt_commitment,
		"provenance_hash": provenance_hash,
		"required_capabilities": capability_result["capabilities"],
		"schema": SCHEMA_VERSION,
		"seed": seed,
		"token_budget": budget_result["token_budget"],
	}
	var job_commitment := _content_commitment({
		"domain": DOMAIN_SEPARATOR,
		"manifest": manifest,
	})
	var job := {
		"advisory_stakes": {},
		"asset_name": asset_name_result["text"],
		"author_id": author_id,
		"completion": {},
		"governance": governance,
		"job_commitment": job_commitment,
		"job_id": job_id,
		"lobby_id": lobby_id,
		"manifest": manifest,
		"modality": modality,
		"model_policy": model_policy,
		"model_policy_hash": model_policy_hash,
		"output_spec": output_spec,
		"partition_plan": {},
		"partition_results": {},
		"prompt": prompt,
		"prompt_commitment": prompt_commitment,
		"provenance": provenance,
		"provenance_hash": provenance_hash,
		"publication": {},
		"review_receipt": {},
		"state": JobState.DRAFT,
	}
	_jobs[job_id] = job
	return {
		"interface_mode": INTERFACE_MODE,
		"job": _job_snapshot(job),
		"ok": true,
		"receipt": _offline_receipt("draft_created"),
	}


func submit_for_review(job_id: String, review_receipt: Dictionary) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.DRAFT)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var normalized := _normalize_review_receipt(review_receipt, job)
	if not normalized.get("ok", false):
		return normalized
	job["review_receipt"] = normalized["receipt"]
	job["state"] = JobState.REVIEW
	return {
		"authoritative": false,
		"job": _job_snapshot(job),
		"ok": true,
		"receipt": _offline_receipt("review_attached_advisory_only"),
	}


func approve_job(job_id: String, consent_receipt: Dictionary) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.REVIEW)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var consent := _validate_unanimous_consent(job, consent_receipt, "asset.generate", "")
	if not consent.get("ok", false):
		return consent
	job["generation_consent"] = consent["receipt"]
	job["state"] = JobState.APPROVED
	return {
		"advisory_stake_authoritative": false,
		"job": _job_snapshot(job),
		"ok": true,
		"receipt": _offline_receipt("unanimous_generation_consent_verified"),
	}


func register_compute_offer(offer: Dictionary) -> Dictionary:
	var unknown := _unknown_field(offer, OFFER_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_compute_offer_field_" + unknown)
	var unsafe := _unsafe_reason(offer, "compute_offer")
	if not unsafe.is_empty():
		return _failure(unsafe)
	var offer_id := _clean_identifier(str(offer.get("offer_id", "")), 80)
	var member_id := _clean_identifier(str(offer.get("member_id", "")), 80)
	if offer_id.is_empty() or member_id.is_empty():
		return _failure("invalid_compute_offer_identity")
	if _offers.has(offer_id):
		return _failure("duplicate_compute_offer")
	var ram_mb := int(offer.get("available_ram_mb", 0))
	if ram_mb < MIN_OFFER_RAM_MB or ram_mb > MAX_OFFER_RAM_MB:
		return _failure("available_ram_mb_out_of_range")
	var max_parallel := int(offer.get("max_parallel_partitions", 0))
	if max_parallel < 1 or max_parallel > MAX_PARALLEL_PARTITIONS:
		return _failure("max_parallel_partitions_out_of_range")
	var epoch := int(offer.get("offer_epoch", -1))
	if epoch < 0:
		return _failure("invalid_offer_epoch")
	var labels_result := _normalize_label_array(offer.get("capability_labels", null), CAPABILITY_LABELS, 16)
	if not labels_result.get("ok", false):
		return _failure("compute_offer_" + str(labels_result.get("reason", "invalid_capabilities")))
	var labels: Array = labels_result["values"]
	if labels.is_empty():
		return _failure("compute_offer_requires_capability")
	var normalized := {
		"available_ram_mb": ram_mb,
		"capability_labels": labels,
		"max_parallel_partitions": max_parallel,
		"member_id": member_id,
		"offer_epoch": epoch,
		"offer_id": offer_id,
	}
	_offers[offer_id] = normalized
	return {
		"interface_mode": INTERFACE_MODE,
		"offer": normalized.duplicate(true),
		"offer_commitment": _content_commitment(normalized),
		"ok": true,
		"receipt": _offline_receipt("metadata_offer_registered"),
	}


func capacity_summary(policy: Dictionary = {}) -> Dictionary:
	## Summarizes registered metadata offers. "Usable" is a conservative planning
	## estimate, not evidence that memory is pooled or that a model can execute.
	var normalized_policy := _normalize_capacity_policy(policy)
	if not normalized_policy.get("ok", false):
		return normalized_policy
	var raw_offered_ram_mb := 0
	for offer_id in _offers:
		raw_offered_ram_mb += int(_offers[offer_id]["available_ram_mb"])
	return _capacity_report(
		_offers.size(),
		raw_offered_ram_mb,
		normalized_policy["policy"],
		"registered_metadata_offers"
	)


func estimate_capacity(
	participant_count: int,
	average_ram_mb: int,
	policy: Dictionary = {}
) -> Dictionary:
	## Scenario calculator for UI copy and planning. It never registers an offer.
	if participant_count < 1 or participant_count > 100_000_000:
		return _failure("participant_count_out_of_range")
	if average_ram_mb < MIN_OFFER_RAM_MB or average_ram_mb > MAX_OFFER_RAM_MB:
		return _failure("average_ram_mb_out_of_range")
	var normalized_policy := _normalize_capacity_policy(policy)
	if not normalized_policy.get("ok", false):
		return normalized_policy
	var raw_offered_ram_mb := participant_count * average_ram_mb
	if raw_offered_ram_mb < 0:
		return _failure("capacity_arithmetic_overflow")
	return _capacity_report(
		participant_count,
		raw_offered_ram_mb,
		normalized_policy["policy"],
		"scenario_estimate_only"
	)


func set_advisory_stakes(job_id: String, entries_value) -> Dictionary:
	var job_result := _get_job(job_id)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	if int(job["state"]) >= JobState.PARTITIONED:
		return _failure("advisory_stake_locked_after_partitioning")
	if not entries_value is Array or entries_value.is_empty() or entries_value.size() > 256:
		return _failure("invalid_advisory_stake_entries")
	var consent_members: Array = job["governance"]["consent_member_ids"]
	var raw_stakes: Dictionary = {}
	var evidence: Dictionary = {}
	var total := 0
	for raw_entry in entries_value:
		if not raw_entry is Dictionary:
			return _failure("advisory_stake_entry_must_be_dictionary")
		var unknown := _unknown_field(raw_entry, STAKE_FIELDS)
		if not unknown.is_empty():
			return _failure("unsupported_advisory_stake_field_" + unknown)
		var unsafe := _unsafe_reason(raw_entry, "advisory_stake")
		if not unsafe.is_empty():
			return _failure(unsafe)
		var member_id := _clean_identifier(str(raw_entry.get("member_id", "")), 80)
		if member_id.is_empty() or member_id not in consent_members or raw_stakes.has(member_id):
			return _failure("invalid_or_duplicate_stake_member")
		var stake_units := int(raw_entry.get("stake_units", -1))
		if stake_units < 0 or stake_units > MAX_ADVISORY_STAKE_UNITS:
			return _failure("advisory_stake_units_out_of_range")
		var evidence_commitment := str(raw_entry.get("evidence_commitment", ""))
		if not _valid_content_commitment(evidence_commitment):
			return _failure("invalid_advisory_evidence_commitment")
		raw_stakes[member_id] = stake_units
		evidence[member_id] = evidence_commitment
		total += stake_units
		if total > MAX_ADVISORY_STAKE_UNITS:
			return _failure("total_advisory_stake_exceeds_limit")

	var weights_basis_points: Dictionary = {}
	var capped_units: Dictionary = {}
	var cap_units := int(ceil(float(total) * float(MAX_ADVISORY_MEMBER_BASIS_POINTS) / 10000.0)) if total > 0 else 0
	for member_id in _sorted_dictionary_keys(raw_stakes):
		var units := int(raw_stakes[member_id])
		weights_basis_points[member_id] = min(MAX_ADVISORY_MEMBER_BASIS_POINTS, int(float(units) * 10000.0 / float(total))) if total > 0 else 0
		capped_units[member_id] = mini(units, cap_units)
	job["advisory_stakes"] = {
		"authoritative": false,
		"capped_units": capped_units,
		"evidence": evidence,
		"max_member_basis_points": MAX_ADVISORY_MEMBER_BASIS_POINTS,
		"raw_units": raw_stakes,
		"total_units": total,
		"weights_basis_points": weights_basis_points,
	}
	return {
		"authoritative": false,
		"job_state_unchanged": true,
		"ok": true,
		"ranking": job["advisory_stakes"].duplicate(true),
		"warning": "Stake ranks capacity offers only; it cannot authorize generation or publication.",
	}


func build_partition_plan(job_id: String) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.APPROVED)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var required_capabilities: Array = job["manifest"]["required_capabilities"]
	var consent_members: Array = job["governance"]["consent_member_ids"]
	var partition_ram_mb := int(job["manifest"]["partition_ram_mb"])
	var estimated_ram_mb := int(job["manifest"]["estimated_ram_mb"])
	var partition_count := int(ceil(float(estimated_ram_mb) / float(partition_ram_mb)))
	if partition_count > MAX_PARTITIONS:
		return _failure("partition_count_exceeds_limit")

	var ranked_offers: Array = []
	for offer_id in _sorted_dictionary_keys(_offers):
		var offer: Dictionary = _offers[offer_id]
		if offer["member_id"] not in consent_members:
			continue
		if not _contains_all(offer["capability_labels"], required_capabilities):
			continue
		if int(offer["available_ram_mb"]) < partition_ram_mb:
			continue
		var ranked := offer.duplicate(true)
		ranked["_capability_surplus"] = int(offer["capability_labels"].size()) - required_capabilities.size()
		ranked["_stake_rank"] = int(job.get("advisory_stakes", {}).get("capped_units", {}).get(offer["member_id"], 0))
		ranked["_slot_count"] = mini(
			int(offer["max_parallel_partitions"]),
			int(offer["available_ram_mb"]) / partition_ram_mb
		)
		if int(ranked["_slot_count"]) > 0:
			ranked_offers.append(ranked)
	ranked_offers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["_capability_surplus"]) != int(b["_capability_surplus"]):
			return int(a["_capability_surplus"]) > int(b["_capability_surplus"])
		if int(a["_stake_rank"]) != int(b["_stake_rank"]):
			return int(a["_stake_rank"]) > int(b["_stake_rank"])
		if int(a["available_ram_mb"]) != int(b["available_ram_mb"]):
			return int(a["available_ram_mb"]) > int(b["available_ram_mb"])
		return str(a["offer_id"]) < str(b["offer_id"])
	)
	if ranked_offers.is_empty():
		return _failure("no_eligible_compute_offers")

	var slots: Array = []
	for round_index in range(MAX_PARALLEL_PARTITIONS):
		for offer in ranked_offers:
			if round_index < int(offer["_slot_count"]):
				slots.append(offer)
	if slots.size() < partition_count:
		return _failure("insufficient_collective_compute_capacity")

	var generation_tokens := int(job["manifest"]["token_budget"]["generation_tokens"])
	var base_tokens := int(generation_tokens / partition_count)
	var token_remainder := generation_tokens % partition_count
	var remaining_ram := estimated_ram_mb
	var partitions: Array = []
	for index in range(partition_count):
		var selected: Dictionary = slots[index]
		var ram_mb := mini(partition_ram_mb, remaining_ram)
		remaining_ram -= ram_mb
		var partition_seed := _derive_seed(int(job["manifest"]["seed"]), index, job["job_commitment"])
		var partition_basis := {
			"index": index,
			"job_commitment": job["job_commitment"],
			"offer_id": selected["offer_id"],
			"ram_mb": ram_mb,
			"seed": partition_seed,
			"token_budget": base_tokens + (1 if index < token_remainder else 0),
		}
		var partition_id := "part-" + hash_value(partition_basis).substr(0, 24)
		partitions.append({
			"capability_labels": required_capabilities.duplicate(),
			"index": index,
			"input_commitment": _content_commitment({
				"model_policy_hash": job["model_policy_hash"],
				"output_spec": job["output_spec"],
				"prompt_commitment": job["prompt_commitment"],
				"provenance_hash": job["provenance_hash"],
			}),
			"member_id": selected["member_id"],
			"offer_id": selected["offer_id"],
			"partition_id": partition_id,
			"ram_limit_mb": ram_mb,
			"seed": partition_seed,
			"token_budget": partition_basis["token_budget"],
		})
	var public_ranked_offers: Array = []
	for ranked in ranked_offers:
		public_ranked_offers.append({
			"advisory_stake_rank": ranked["_stake_rank"],
			"available_ram_mb": ranked["available_ram_mb"],
			"capability_surplus": ranked["_capability_surplus"],
			"member_id": ranked["member_id"],
			"offer_id": ranked["offer_id"],
			"slot_count": ranked["_slot_count"],
		})
	var plan := {
		"advisory_stake_authoritative": false,
		"deterministic_selection": true,
		"job_commitment": job["job_commitment"],
		"partitions": partitions,
		"ranked_offers": public_ranked_offers,
	}
	plan["plan_commitment"] = _content_commitment(plan)
	job["partition_plan"] = plan
	job["state"] = JobState.PARTITIONED
	return {
		"interface_mode": INTERFACE_MODE,
		"network_dispatch_performed": false,
		"ok": true,
		"plan": plan.duplicate(true),
		"receipt": _offline_receipt("deterministic_partition_plan_built"),
	}


func build_local_worker_request(job_id: String, partition_id: String) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.PARTITIONED)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var partition := _find_partition(job, partition_id)
	if partition.is_empty():
		return _failure("partition_not_found")
	return {
		"ok": true,
		"request": {
			"capability_labels": partition["capability_labels"].duplicate(),
			"code_execution": false,
			"interface_mode": INTERFACE_MODE,
			"job_id": job["job_id"],
			"modality": job["modality"],
			"model_policy": job["model_policy"].duplicate(true),
			"network_access": false,
			"offer_id": partition["offer_id"],
			"output_spec": job["output_spec"].duplicate(true),
			"partition_id": partition["partition_id"],
			"prompt": job["prompt"].duplicate(true),
			"ram_limit_mb": partition["ram_limit_mb"],
			"seed": partition["seed"],
			"token_budget": partition["token_budget"],
			"tools": [],
		},
	}


func record_partition_result(job_id: String, partition_id: String, result: Dictionary) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.PARTITIONED)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var partition := _find_partition(job, partition_id)
	if partition.is_empty():
		return _failure("partition_not_found")
	if job["partition_results"].has(partition_id):
		return _failure("duplicate_partition_result")
	var unknown := _unknown_field(result, RESULT_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_partition_result_field_" + unknown)
	var unsafe := _unsafe_reason(result, "partition_result")
	if not unsafe.is_empty():
		return _failure(unsafe)
	for hash_field in ["model_receipt_hash", "output_hash", "provenance_hash", "safety_review_hash"]:
		if not _valid_content_commitment(str(result.get(hash_field, ""))):
			return _failure("invalid_" + hash_field)
	if str(result.get("model_policy_hash", "")) != job["model_policy_hash"]:
		return _failure("model_policy_hash_mismatch")
	if str(result.get("prompt_commitment", "")) != job["prompt_commitment"]:
		return _failure("prompt_commitment_mismatch")
	if str(result.get("provenance_hash", "")) != job["provenance_hash"]:
		return _failure("provenance_hash_mismatch")
	if str(result.get("offer_id", "")) != partition["offer_id"]:
		return _failure("partition_offer_mismatch")
	if int(result.get("seed", -1)) != int(partition["seed"]):
		return _failure("partition_seed_mismatch")
	var expected_mime := _mime_type_for(job["modality"], job["output_spec"]["format"])
	if str(result.get("mime_type", "")) != expected_mime:
		return _failure("partition_mime_type_mismatch")
	var byte_size := int(result.get("byte_size", -1))
	var max_bytes := int(job["output_spec"]["max_output_mb"]) * 1024 * 1024
	if byte_size < 1 or byte_size > max_bytes:
		return _failure("partition_output_size_out_of_range")
	var normalized := result.duplicate(true)
	normalized["partition_id"] = partition_id
	normalized["result_commitment"] = _content_commitment({
		"partition": partition,
		"result": result,
	})
	job["partition_results"][partition_id] = normalized
	return {
		"accepted_result_count": job["partition_results"].size(),
		"expected_result_count": job["partition_plan"]["partitions"].size(),
		"ok": true,
		"receipt": _offline_receipt("partition_commitment_recorded"),
		"result_commitment": normalized["result_commitment"],
	}


func complete_job(job_id: String) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.PARTITIONED)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var result_entries: Array = []
	for partition in job["partition_plan"]["partitions"]:
		var partition_id: String = partition["partition_id"]
		if not job["partition_results"].has(partition_id):
			return _failure("missing_partition_result_" + partition_id)
		var result: Dictionary = job["partition_results"][partition_id]
		result_entries.append({
			"byte_size": result["byte_size"],
			"mime_type": result["mime_type"],
			"output_hash": result["output_hash"],
			"partition_id": partition_id,
			"result_commitment": result["result_commitment"],
			"safety_review_hash": result["safety_review_hash"],
		})
	var content_manifest := {
		"interface_mode": INTERFACE_MODE,
		"job_commitment": job["job_commitment"],
		"model_policy_hash": job["model_policy_hash"],
		"partition_plan_commitment": job["partition_plan"]["plan_commitment"],
		"prompt_commitment": job["prompt_commitment"],
		"provenance_hash": job["provenance_hash"],
		"results": result_entries,
		"schema": SCHEMA_VERSION,
	}
	var manifest_digest := hash_value(content_manifest)
	var completion := {
		"content_commitment": "sha256:" + manifest_digest,
		"content_manifest": content_manifest,
		"draft_cid": _cid_v1_dag_json(manifest_digest),
		"ipfs_add_performed": false,
		"network_io_performed": false,
		"status": "local_draft_cid_ready",
	}
	completion["completion_receipt_hash"] = _content_commitment(completion)
	job["completion"] = completion
	job["state"] = JobState.COMPLETED
	return {
		"completion": completion.duplicate(true),
		"job": _job_snapshot(job),
		"ok": true,
		"receipt": _offline_receipt("content_manifest_completed"),
	}


func publish_job(job_id: String, consent_receipt: Dictionary) -> Dictionary:
	var job_result := _job_for_state(job_id, JobState.COMPLETED)
	if not job_result.get("ok", false):
		return job_result
	var job: Dictionary = job_result["job"]
	var output_commitment: String = job["completion"]["content_commitment"]
	var consent := _validate_unanimous_consent(job, consent_receipt, "asset.publish", output_commitment)
	if not consent.get("ok", false):
		return consent
	var publication := {
		"blockchain_write_performed": false,
		"consent_receipt_hash": consent["receipt"]["receipt_hash"],
		"content_commitment": output_commitment,
		"draft_cid": job["completion"]["draft_cid"],
		"interface_mode": INTERFACE_MODE,
		"ipfs_add_performed": false,
		"network_io_performed": false,
		"publication_status": "published_to_local_interface_manifest_only",
	}
	publication["publication_receipt_hash"] = _content_commitment(publication)
	job["publication"] = publication
	job["state"] = JobState.PUBLISHED
	return {
		"job": _job_snapshot(job),
		"ok": true,
		"publication": publication.duplicate(true),
	}


func get_job_snapshot(job_id: String) -> Dictionary:
	var result := _get_job(job_id)
	if not result.get("ok", false):
		return result
	return {"ok": true, "job": _job_snapshot(result["job"])}


func get_interface_snapshot() -> Dictionary:
	return {
		"arbitrary_code_accepted": false,
		"blockchain_writes_available": false,
		"interface_mode": INTERFACE_MODE,
		"ipfs_network_available": false,
		"job_count": _jobs.size(),
		"live_model_execution_available": false,
		"network_access_available": false,
		"offer_count": _offers.size(),
		"private_material_accepted": false,
		"schema": SCHEMA_VERSION,
	}


static func state_name(state: int) -> String:
	match state:
		JobState.DRAFT: return "draft"
		JobState.REVIEW: return "review"
		JobState.APPROVED: return "approved"
		JobState.PARTITIONED: return "partitioned"
		JobState.COMPLETED: return "completed"
		JobState.PUBLISHED: return "published"
		_: return "unknown"


static func canonical_json(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return "null"
			return JSON.stringify(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(str(value))
		TYPE_ARRAY:
			var array_parts: Array[String] = []
			for item in value:
				array_parts.append(canonical_json(item))
			return "[" + ",".join(array_parts) + "]"
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return canonical_json(Array(value))
		TYPE_DICTIONARY:
			var dictionary_parts: Array[String] = []
			for key in value.keys():
				dictionary_parts.append(JSON.stringify(str(key)) + ":" + canonical_json(value[key]))
			dictionary_parts.sort()
			return "{" + ",".join(dictionary_parts) + "}"
		_:
			return JSON.stringify(str(value))


static func hash_value(value) -> String:
	return canonical_json(value).sha256_text()


static func consent_receipt_hash(receipt: Dictionary) -> String:
	var unhashed := receipt.duplicate(true)
	unhashed.erase("receipt_hash")
	unhashed.erase("proof")
	return hash_value(unhashed)


func _normalize_governance_binding(value) -> Dictionary:
	if not value is Dictionary:
		return _failure("governance_binding_must_be_dictionary")
	var unknown := _unknown_field(value, GOVERNANCE_BINDING_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_governance_binding_field_" + unknown)
	var proposal_id := _clean_identifier(str(value.get("proposal_id", "")), 80)
	if proposal_id.is_empty():
		return _failure("invalid_governance_proposal_id")
	var proposal_hash := str(value.get("proposal_hash", ""))
	var manifest_hash := str(value.get("manifest_hash", ""))
	if not _valid_digest(proposal_hash) or not _valid_digest(manifest_hash):
		return _failure("invalid_governance_hash_binding")
	var members_result := _normalize_identifier_array(value.get("consent_member_ids", null), 256)
	if not members_result.get("ok", false) or members_result["values"].is_empty():
		return _failure("invalid_consent_member_ids")
	return {
		"binding": {
			"consent_member_ids": members_result["values"],
			"manifest_hash": manifest_hash,
			"proposal_hash": proposal_hash,
			"proposal_id": proposal_id,
		},
		"ok": true,
	}


func _normalize_prompt(value) -> Dictionary:
	if not value is Dictionary:
		return _failure("prompt_must_be_structured_dictionary")
	var unknown := _unknown_field(value, PROMPT_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_prompt_field_" + unknown)
	if not value.has("intent"):
		return _failure("prompt_intent_required")
	var prompt: Dictionary = {}
	for field in PROMPT_LIMITS.keys():
		if value.has(field):
			var normalized := _normalize_text(str(value[field]), int(PROMPT_LIMITS[field]), field != "intent")
			if not normalized.get("ok", false):
				return _failure("prompt_" + String(field) + "_" + str(normalized.get("reason", "invalid")))
			prompt[field] = normalized["text"]
		elif field == "intent":
			return _failure("prompt_intent_required")
	var locale := str(value.get("locale", "en-US"))
	if not _matches(locale, "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$"):
		return _failure("invalid_prompt_locale")
	prompt["locale"] = locale
	var tags_result := _normalize_label_array(value.get("style_tags", []), [], 24)
	if not tags_result.get("ok", false):
		return _failure("invalid_prompt_style_tags")
	prompt["style_tags"] = tags_result["values"]
	var serialized := canonical_json(prompt)
	if serialized.to_utf8_buffer().size() > MAX_PROMPT_BYTES:
		return _failure("prompt_total_bytes_exceed_limit")
	if serialized.count("\n") + 1 > MAX_PROMPT_LINES:
		return _failure("prompt_line_count_exceeds_limit")
	var unsafe := _unsafe_text_reason(serialized)
	if not unsafe.is_empty():
		return _failure("prompt_" + unsafe)
	return {"ok": true, "prompt": prompt}


func _normalize_output_spec(modality: String, value) -> Dictionary:
	if not value is Dictionary:
		return _failure("output_spec_must_be_dictionary")
	var allowed: Dictionary = {"format": true, "max_output_mb": true}
	match modality:
		"image":
			allowed.merge({"height": true, "steps": true, "width": true})
		"audio":
			allowed.merge({"channels": true, "duration_seconds": true, "sample_rate_hz": true})
		"voice_to_text":
			allowed.merge({"language": true, "max_seconds": true, "source_input_commitment": true})
		"world":
			allowed.merge({"detail_level": true, "height_chunks": true, "width_chunks": true})
		"model":
			allowed.merge({"artifact_kind": true, "texture_resolution": true, "triangle_budget": true})
	var unknown := _unknown_field(value, allowed)
	if not unknown.is_empty():
		return _failure("unsupported_output_spec_field_" + unknown)
	var max_output_mb := int(value.get("max_output_mb", 0))
	if max_output_mb < 1 or max_output_mb > 8192:
		return _failure("max_output_mb_out_of_range")
	var expected_formats := {
		"audio": ["wav"],
		"image": ["png", "webp"],
		"model": ["glb"],
		"voice_to_text": ["json", "text"],
		"world": ["nexus-world-json"],
	}
	var format := str(value.get("format", "")).to_lower()
	if format not in expected_formats[modality]:
		return _failure("unsupported_output_format")
	var normalized := {"format": format, "max_output_mb": max_output_mb}
	match modality:
		"image":
			var width := int(value.get("width", 0))
			var height := int(value.get("height", 0))
			var steps := int(value.get("steps", 0))
			if width < 64 or width > 8192 or height < 64 or height > 8192:
				return _failure("image_dimensions_out_of_range")
			if steps < 1 or steps > 250:
				return _failure("image_steps_out_of_range")
			normalized.merge({"height": height, "steps": steps, "width": width})
		"audio":
			var duration := int(value.get("duration_seconds", 0))
			var rate := int(value.get("sample_rate_hz", 0))
			var channels := int(value.get("channels", 0))
			if duration < 1 or duration > 1800:
				return _failure("audio_duration_out_of_range")
			if rate not in [16000, 22050, 24000, 44100, 48000]:
				return _failure("audio_sample_rate_not_allowed")
			if channels not in [1, 2]:
				return _failure("audio_channels_not_allowed")
			normalized.merge({"channels": channels, "duration_seconds": duration, "sample_rate_hz": rate})
		"voice_to_text":
			var language := str(value.get("language", ""))
			var max_seconds := int(value.get("max_seconds", 0))
			var source_commitment := str(value.get("source_input_commitment", ""))
			if not _matches(language, "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$"):
				return _failure("invalid_transcription_language")
			if max_seconds < 1 or max_seconds > 7200:
				return _failure("transcription_duration_out_of_range")
			if not _valid_content_commitment(source_commitment):
				return _failure("invalid_source_input_commitment")
			normalized.merge({"language": language, "max_seconds": max_seconds, "source_input_commitment": source_commitment})
		"world":
			var width_chunks := int(value.get("width_chunks", 0))
			var height_chunks := int(value.get("height_chunks", 0))
			var detail_level := int(value.get("detail_level", 0))
			if width_chunks < 1 or width_chunks > 4096 or height_chunks < 1 or height_chunks > 4096:
				return _failure("world_dimensions_out_of_range")
			if detail_level < 1 or detail_level > 8:
				return _failure("world_detail_level_out_of_range")
			normalized.merge({"detail_level": detail_level, "height_chunks": height_chunks, "width_chunks": width_chunks})
		"model":
			var artifact_kind := str(value.get("artifact_kind", ""))
			var triangle_budget := int(value.get("triangle_budget", 0))
			var texture_resolution := int(value.get("texture_resolution", 0))
			if artifact_kind not in ["board", "environment", "piece", "prop", "token"]:
				return _failure("model_artifact_kind_not_allowed")
			if triangle_budget < 16 or triangle_budget > 10_000_000:
				return _failure("triangle_budget_out_of_range")
			if texture_resolution not in [256, 512, 1024, 2048, 4096, 8192]:
				return _failure("texture_resolution_not_allowed")
			normalized.merge({"artifact_kind": artifact_kind, "texture_resolution": texture_resolution, "triangle_budget": triangle_budget})
	return {"ok": true, "output_spec": normalized}


func _normalize_capabilities(value, modality: String) -> Dictionary:
	var labels := _normalize_label_array(value, CAPABILITY_LABELS, 16)
	if not labels.get("ok", false):
		return _failure("invalid_required_capabilities")
	var capabilities: Array = labels["values"]
	if MODALITY_CAPABILITY[modality] not in capabilities:
		return _failure("missing_modality_capability")
	return {"capabilities": capabilities, "ok": true}


func _normalize_contributions(value, consent_members: Array) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > consent_members.size():
		return _failure("invalid_contribution_budgets")
	var by_member: Dictionary = {}
	var total := 0
	for raw in value:
		if not raw is Dictionary:
			return _failure("contribution_budget_must_be_dictionary")
		var unknown := _unknown_field(raw, CONTRIBUTION_FIELDS)
		if not unknown.is_empty():
			return _failure("unsupported_contribution_field_" + unknown)
		var member_id := _clean_identifier(str(raw.get("member_id", "")), 80)
		if member_id.is_empty() or member_id not in consent_members or by_member.has(member_id):
			return _failure("invalid_or_duplicate_contributor")
		var token_budget := int(raw.get("token_budget", 0))
		if token_budget < 1 or token_budget > MAX_MEMBER_CONTRIBUTION_TOKENS:
			return _failure("member_token_budget_out_of_range")
		by_member[member_id] = token_budget
		total += token_budget
	if total < MIN_TOTAL_CONTRIBUTION_TOKENS or total > MAX_TOTAL_CONTRIBUTION_TOKENS:
		return _failure("total_token_budget_out_of_range")
	var contributions: Array = []
	for member_id in _sorted_dictionary_keys(by_member):
		contributions.append({"member_id": member_id, "token_budget": by_member[member_id]})
	var review_tokens := maxi(64, int(total / 10))
	return {
		"contributions": contributions,
		"ok": true,
		"token_budget": {
			"generation_tokens": total - review_tokens,
			"review_reserve_tokens": review_tokens,
			"total_contribution_tokens": total,
		},
	}


func _normalize_model_policy(value, modality: String) -> Dictionary:
	if not value is Dictionary:
		return _failure("model_policy_must_be_dictionary")
	var unknown := _unknown_field(value, MODEL_POLICY_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_model_policy_field_" + unknown)
	var unsafe := _unsafe_reason(value, "model_policy")
	if not unsafe.is_empty():
		return _failure(unsafe)
	for field in ["model_id", "model_family", "model_version", "license_id", "safety_profile", "training_data_declaration"]:
		if not value.has(field):
			return _failure("model_policy_missing_" + String(field))
		var normalized := _normalize_text(str(value[field]), 120, false)
		if not normalized.get("ok", false):
			return _failure("invalid_model_policy_" + String(field))
	var execution_mode := str(value.get("execution_mode", ""))
	if execution_mode not in ["interface_simulation", "local_only"]:
		return _failure("model_execution_mode_not_local")
	if bool(value.get("network_access", true)) or bool(value.get("tool_access", true)) or bool(value.get("code_execution", true)):
		return _failure("model_policy_requests_unsafe_capability")
	if not _valid_content_commitment(str(value.get("weights_commitment", ""))):
		return _failure("invalid_model_weights_commitment")
	var modalities := _normalize_label_array(value.get("allowed_modalities", null), MODALITIES, MODALITIES.size())
	if not modalities.get("ok", false) or modality not in modalities["values"]:
		return _failure("model_policy_does_not_allow_modality")
	var normalized_policy := {
		"allowed_modalities": modalities["values"],
		"code_execution": false,
		"execution_mode": execution_mode,
		"license_id": str(value["license_id"]).strip_edges(),
		"model_family": str(value["model_family"]).strip_edges(),
		"model_id": str(value["model_id"]).strip_edges(),
		"model_version": str(value["model_version"]).strip_edges(),
		"network_access": false,
		"safety_profile": str(value["safety_profile"]).strip_edges(),
		"tool_access": false,
		"training_data_declaration": str(value["training_data_declaration"]).strip_edges(),
		"weights_commitment": str(value["weights_commitment"]),
	}
	return {"model_policy": normalized_policy, "ok": true}


func _normalize_provenance(value, consent_members: Array) -> Dictionary:
	if not value is Dictionary:
		return _failure("provenance_must_be_dictionary")
	var unknown := _unknown_field(value, PROVENANCE_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_provenance_field_" + unknown)
	var unsafe := _unsafe_reason(value, "provenance")
	if not unsafe.is_empty():
		return _failure(unsafe)
	var creators := _normalize_identifier_array(value.get("creator_member_ids", null), 256)
	if not creators.get("ok", false) or creators["values"].is_empty():
		return _failure("invalid_provenance_creators")
	for member_id in creators["values"]:
		if member_id not in consent_members:
			return _failure("provenance_creator_not_in_lobby")
	var sources := _normalize_commitment_array(value.get("source_commitments", null), 256, false)
	if not sources.get("ok", false):
		return _failure("invalid_source_commitments")
	var parents := _normalize_cid_array(value.get("parent_asset_cids", []), 256)
	if not parents.get("ok", false):
		return _failure("invalid_parent_asset_cids")
	var licenses := _normalize_label_array(value.get("license_ids", null), [], 64)
	if not licenses.get("ok", false) or licenses["values"].is_empty():
		return _failure("invalid_provenance_license_ids")
	var build_result := _normalize_text(str(value.get("generator_build", "")), 120, false)
	if not build_result.get("ok", false):
		return _failure("invalid_generator_build")
	var created_at_bucket := int(value.get("created_at_bucket", -1))
	if created_at_bucket < 0:
		return _failure("invalid_provenance_time_bucket")
	return {
		"ok": true,
		"provenance": {
			"created_at_bucket": created_at_bucket,
			"creator_member_ids": creators["values"],
			"generator_build": build_result["text"],
			"license_ids": licenses["values"],
			"parent_asset_cids": parents["values"],
			"source_commitments": sources["values"],
		},
	}


func _normalize_review_receipt(receipt: Dictionary, job: Dictionary) -> Dictionary:
	var unknown := _unknown_field(receipt, REVIEW_RECEIPT_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_review_receipt_field_" + unknown)
	for required in REVIEW_RECEIPT_FIELDS.keys():
		if not receipt.has(required):
			return _failure("review_receipt_missing_" + String(required))
	var unsafe := _unsafe_reason(receipt, "review_receipt")
	if not unsafe.is_empty():
		return _failure(unsafe)
	if str(receipt["proposal_hash"]) != job["governance"]["proposal_hash"]:
		return _failure("review_proposal_hash_mismatch")
	if str(receipt["manifest_hash"]) != job["governance"]["manifest_hash"]:
		return _failure("review_manifest_hash_mismatch")
	if not _valid_digest(str(receipt["review_hash"])):
		return _failure("invalid_review_hash")
	if str(receipt["disposition"]) != "allow":
		return _failure("review_did_not_allow")
	if bool(receipt["authoritative"]):
		return _failure("review_must_be_non_authoritative")
	var source := _clean_identifier(str(receipt["source"]), 80)
	if source.is_empty():
		return _failure("invalid_review_source")
	var normalized := receipt.duplicate(true)
	normalized["source"] = source
	return {"ok": true, "receipt": normalized}


func _validate_unanimous_consent(job: Dictionary, receipt: Dictionary, scope: String, output_commitment: String) -> Dictionary:
	var unknown := _unknown_field(receipt, CONSENT_RECEIPT_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_consent_receipt_field_" + unknown)
	for required in CONSENT_RECEIPT_FIELDS.keys():
		if required == "output_commitment" and scope == "asset.generate":
			continue
		if not receipt.has(required):
			return _failure("consent_receipt_missing_" + String(required))
	var unsafe := _unsafe_reason(receipt, "consent_receipt")
	if not unsafe.is_empty():
		return _failure(unsafe)
	if str(receipt.get("scope", "")) != scope:
		return _failure("consent_scope_mismatch")
	if str(receipt.get("proposal_hash", "")) != job["governance"]["proposal_hash"]:
		return _failure("consent_proposal_hash_mismatch")
	if str(receipt.get("manifest_hash", "")) != job["governance"]["manifest_hash"]:
		return _failure("consent_manifest_hash_mismatch")
	if str(receipt.get("review_hash", "")) != job["review_receipt"]["review_hash"]:
		return _failure("consent_review_hash_mismatch")
	if scope == "asset.publish" and str(receipt.get("output_commitment", "")) != output_commitment:
		return _failure("publish_output_commitment_mismatch")
	if scope == "asset.generate" and receipt.has("output_commitment") and not str(receipt["output_commitment"]).is_empty():
		return _failure("generation_consent_must_not_bind_unknown_output")
	var required_result := _normalize_identifier_array(receipt.get("required_member_ids", null), 256)
	var approved_result := _normalize_identifier_array(receipt.get("approved_member_ids", null), 256)
	if not required_result.get("ok", false) or not approved_result.get("ok", false):
		return _failure("invalid_consent_member_sets")
	var expected_members: Array = job["governance"]["consent_member_ids"].duplicate()
	if required_result["values"] != expected_members:
		return _failure("required_consent_members_mismatch")
	if approved_result["values"] != expected_members:
		return _failure("unanimous_member_consent_required")
	if not bool(receipt.get("unanimous", false)):
		return _failure("unanimous_member_consent_required")
	var supplied_receipt_hash := str(receipt.get("receipt_hash", ""))
	if not _valid_digest(supplied_receipt_hash) or supplied_receipt_hash != consent_receipt_hash(receipt):
		return _failure("consent_receipt_hash_mismatch")
	var proof_result := _normalize_proof(receipt.get("proof", null))
	if not proof_result.get("ok", false):
		return proof_result
	if not _governance_proof_verifier.is_valid():
		return _failure("governance_proof_verifier_not_configured")
	var expected_proof := {
		"job_id": job["job_id"],
		"purpose": "generation_governance_consent",
		"receipt_hash": supplied_receipt_hash,
		"scope": scope,
	}
	if not bool(_governance_proof_verifier.call(proof_result["proof"], expected_proof)):
		return _failure("governance_consent_proof_invalid")
	var normalized := receipt.duplicate(true)
	normalized["proof"] = proof_result["proof"]
	return {"ok": true, "receipt": normalized}


func _normalize_proof(value) -> Dictionary:
	if not value is Dictionary:
		return _failure("consent_proof_must_be_dictionary")
	var unknown := _unknown_field(value, PROOF_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_consent_proof_field_" + unknown)
	for required in PROOF_FIELDS.keys():
		if not value.has(required):
			return _failure("consent_proof_missing_" + String(required))
	var algorithm := str(value["algorithm"])
	if algorithm not in ["dilithium3", "ed25519", "hybrid-ed25519-dilithium3", "interface-test-sha256"]:
		return _failure("consent_proof_algorithm_not_allowed")
	var key_id := _clean_identifier(str(value["key_id"]), 120)
	if key_id.is_empty():
		return _failure("invalid_consent_proof_key_id")
	var signature := str(value["signature"])
	if signature.length() < 16 or signature.length() > 1024 or not _matches(signature, "^[A-Za-z0-9_+=:/.-]+$"):
		return _failure("invalid_consent_proof_signature")
	return {"ok": true, "proof": {"algorithm": algorithm, "key_id": key_id, "signature": signature}}


func _normalize_capacity_policy(value: Dictionary) -> Dictionary:
	var unknown := _unknown_field(value, CAPACITY_POLICY_FIELDS)
	if not unknown.is_empty():
		return _failure("unsupported_capacity_policy_field_" + unknown)
	var availability_basis_points := int(value.get("availability_basis_points", 8000))
	var headroom_basis_points := int(value.get("headroom_basis_points", 2000))
	var replication_factor := int(value.get("replication_factor", 2))
	if availability_basis_points < 1 or availability_basis_points > 10000:
		return _failure("availability_basis_points_out_of_range")
	if headroom_basis_points < 0 or headroom_basis_points > 9000:
		return _failure("headroom_basis_points_out_of_range")
	if replication_factor < 1 or replication_factor > 16:
		return _failure("replication_factor_out_of_range")
	return {
		"ok": true,
		"policy": {
			"availability_basis_points": availability_basis_points,
			"headroom_basis_points": headroom_basis_points,
			"replication_factor": replication_factor,
		},
	}


func _capacity_report(participant_count: int, raw_offered_ram_mb: int, policy: Dictionary, source: String) -> Dictionary:
	var availability_adjusted_ram_mb := int(
		raw_offered_ram_mb * int(policy["availability_basis_points"]) / 10000
	)
	var headroom_adjusted_ram_mb := int(
		availability_adjusted_ram_mb * (10000 - int(policy["headroom_basis_points"])) / 10000
	)
	var replication_adjusted_usable_ram_mb := int(
		headroom_adjusted_ram_mb / int(policy["replication_factor"])
	)
	return {
		"availability_adjusted_ram_mb": availability_adjusted_ram_mb,
		"execution_guaranteed": false,
		"headroom_adjusted_ram_mb": headroom_adjusted_ram_mb,
		"interface_mode": INTERFACE_MODE,
		"model_execution_available": false,
		"network_pool_created": false,
		"ok": true,
		"participant_count": participant_count,
		"policy": policy.duplicate(true),
		"ram_alone_is_execution_proof": false,
		"raw_offered_ram_mb": raw_offered_ram_mb,
		"replication_adjusted_usable_ram_mb": replication_adjusted_usable_ram_mb,
		"required_external_evidence": [
			"compatible_model_partition_strategy",
			"measured_interconnect_bandwidth_and_latency",
			"worker_attestation_and_runtime_compatibility",
			"model_license_and_weight_availability",
			"fault_tolerance_and_checkpoint_validation",
		],
		"source": source,
	}


func _normalize_text(value: String, max_characters: int, allow_empty: bool) -> Dictionary:
	if value.length() > max_characters or value.to_utf8_buffer().size() > max_characters * 4:
		return {"ok": false, "reason": "too_long"}
	var normalized := value.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ").strip_edges()
	if normalized.is_empty() and not allow_empty:
		return {"ok": false, "reason": "empty"}
	for index in range(normalized.length()):
		var code := normalized.unicode_at(index)
		if code < 32 and code != 10:
			return {"ok": false, "reason": "control_character"}
	var unsafe := _unsafe_text_reason(normalized)
	if not unsafe.is_empty():
		return {"ok": false, "reason": unsafe}
	return {"ok": true, "text": normalized}


func _normalize_label_array(value, allowlist: Array, maximum: int) -> Dictionary:
	if not value is Array and not value is PackedStringArray:
		return {"ok": false, "reason": "must_be_array"}
	if value.size() > maximum:
		return {"ok": false, "reason": "too_many_values"}
	var values: Array = []
	for raw in value:
		var label := str(raw).strip_edges().to_lower()
		if label.is_empty() or label.length() > 80 or not _matches(label, "^[a-z0-9][a-z0-9._-]{0,79}$"):
			return {"ok": false, "reason": "invalid_label"}
		if not allowlist.is_empty() and label not in allowlist:
			return {"ok": false, "reason": "label_not_allowed"}
		if label in values:
			return {"ok": false, "reason": "duplicate_label"}
		values.append(label)
	values.sort()
	return {"ok": true, "values": values}


func _normalize_identifier_array(value, maximum: int) -> Dictionary:
	if not value is Array and not value is PackedStringArray:
		return {"ok": false, "reason": "must_be_array"}
	if value.size() > maximum:
		return {"ok": false, "reason": "too_many_values"}
	var values: Array = []
	for raw in value:
		var identifier := _clean_identifier(str(raw), 80)
		if identifier.is_empty() or identifier in values:
			return {"ok": false, "reason": "invalid_or_duplicate_identifier"}
		values.append(identifier)
	values.sort()
	return {"ok": true, "values": values}


func _normalize_commitment_array(value, maximum: int, require_nonempty: bool) -> Dictionary:
	if not value is Array and not value is PackedStringArray:
		return {"ok": false, "reason": "must_be_array"}
	if value.size() > maximum or (require_nonempty and value.is_empty()):
		return {"ok": false, "reason": "invalid_count"}
	var values: Array = []
	for raw in value:
		var commitment := str(raw)
		if not _valid_content_commitment(commitment) or commitment in values:
			return {"ok": false, "reason": "invalid_or_duplicate_commitment"}
		values.append(commitment)
	values.sort()
	return {"ok": true, "values": values}


func _normalize_cid_array(value, maximum: int) -> Dictionary:
	if not value is Array and not value is PackedStringArray:
		return {"ok": false, "reason": "must_be_array"}
	if value.size() > maximum:
		return {"ok": false, "reason": "too_many_values"}
	var values: Array = []
	for raw in value:
		var cid := str(raw).to_lower()
		if not _valid_cid(cid) or cid in values:
			return {"ok": false, "reason": "invalid_or_duplicate_cid"}
		values.append(cid)
	values.sort()
	return {"ok": true, "values": values}


func _job_snapshot(job: Dictionary) -> Dictionary:
	return {
		"advisory_stake_authoritative": false,
		"asset_name": job["asset_name"],
		"author_id": job["author_id"],
		"completion": job["completion"].duplicate(true),
		"governance_binding": job["governance"].duplicate(true),
		"interface_mode": INTERFACE_MODE,
		"job_commitment": job["job_commitment"],
		"job_id": job["job_id"],
		"lobby_id": job["lobby_id"],
		"manifest": job["manifest"].duplicate(true),
		"modality": job["modality"],
		"partition_plan_commitment": job["partition_plan"].get("plan_commitment", ""),
		"prompt_commitment": job["prompt_commitment"],
		"publication": job["publication"].duplicate(true),
		"state": job["state"],
		"state_name": state_name(job["state"]),
	}


func _get_job(job_id_value: String) -> Dictionary:
	var job_id := _clean_identifier(job_id_value, 80)
	if job_id.is_empty() or not _jobs.has(job_id):
		return _failure("job_not_found")
	return {"job": _jobs[job_id], "ok": true}


func _job_for_state(job_id: String, required_state: int) -> Dictionary:
	var result := _get_job(job_id)
	if not result.get("ok", false):
		return result
	if int(result["job"]["state"]) != required_state:
		return _failure("invalid_job_state_expected_" + state_name(required_state))
	return result


func _find_partition(job: Dictionary, partition_id: String) -> Dictionary:
	for partition in job.get("partition_plan", {}).get("partitions", []):
		if partition["partition_id"] == partition_id:
			return partition
	return {}


func _contains_all(haystack: Array, needles: Array) -> bool:
	for needle in needles:
		if needle not in haystack:
			return false
	return true


func _derive_seed(base_seed: int, partition_index: int, job_commitment: String) -> int:
	var digest := hash_value({"base_seed": base_seed, "job_commitment": job_commitment, "partition_index": partition_index})
	return int(digest.substr(0, 7).hex_to_int())


func _mime_type_for(modality: String, format: String) -> String:
	var key := modality + ":" + format
	return {
		"audio:wav": "audio/wav",
		"image:png": "image/png",
		"image:webp": "image/webp",
		"model:glb": "model/gltf-binary",
		"voice_to_text:json": "application/json",
		"voice_to_text:text": "text/plain",
		"world:nexus-world-json": "application/vnd.nexus.world+json",
	}.get(key, "application/octet-stream")


func _unsafe_reason(value, path: String, depth: int = 0) -> String:
	if depth > 10:
		return "value_nesting_exceeds_limit"
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME:
			var reason := _unsafe_text_reason(str(value))
			return path.replace(".", "_") + "_" + reason if not reason.is_empty() else ""
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY:
			if value.size() > 4096:
				return "array_exceeds_limit"
			for index in range(value.size()):
				var reason := _unsafe_reason(value[index], path + "_item", depth + 1)
				if not reason.is_empty():
					return reason
		TYPE_DICTIONARY:
			if value.size() > 512:
				return "dictionary_exceeds_limit"
			for raw_key in value.keys():
				var key := str(raw_key).to_lower()
				for forbidden in FORBIDDEN_FIELD_PARTS:
					if key.contains(forbidden):
						return "forbidden_field_" + forbidden
				var reason := _unsafe_reason(value[raw_key], path + "_" + key, depth + 1)
				if not reason.is_empty():
					return reason
	return ""


func _unsafe_text_reason(value: String) -> String:
	var lower := value.to_lower()
	for marker in INJECTION_MARKERS:
		if lower.contains(marker):
			return "prompt_injection_marker"
	if _matches(value, "(?i).*(?:https?|ftp|file|ipfs|ws|wss)://.*") or _matches(value, "(?i).*\\bwww\\..*"):
		return "url_not_allowed"
	if _matches(value, ".*(?:^|[^0-9])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?:[^0-9]|$).*"):
		return "raw_ip_not_allowed"
	if _matches(value, "(?i).*(?:[0-9a-f]{1,4}:){2,}[0-9a-f]{0,4}.*"):
		return "raw_ip_not_allowed"
	if _matches(value, "(?i).*-----BEGIN [A-Z ]*PRIVATE KEY-----.*"):
		return "private_key_material_not_allowed"
	if _matches(value, "(?i).*(?:sk-[A-Za-z0-9_-]{12,}|api[ _-]?key\\s*[:=]|password\\s*[:=]|bearer\\s+[A-Za-z0-9._-]{8,}|seed phrase\\s*[:=]|mnemonic\\s*[:=]).*"):
		return "secret_material_not_allowed"
	return ""


func _unknown_field(value: Dictionary, allowed: Dictionary) -> String:
	var keys: Array = value.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	for raw_key in keys:
		var key := str(raw_key)
		if not allowed.has(key):
			return key
	return ""


func _clean_identifier(value: String, maximum: int) -> String:
	var clean := value.strip_edges().to_lower()
	if clean.length() < 2 or clean.length() > maximum:
		return ""
	if not _matches(clean, "^[a-z0-9][a-z0-9._-]+$"):
		return ""
	return clean


func _valid_digest(value: String) -> bool:
	return _matches(value, "^[a-f0-9]{64}$")


func _valid_content_commitment(value: String) -> bool:
	return _matches(value, "^sha256:[a-f0-9]{64}$")


func _valid_cid(value: String) -> bool:
	return _matches(value, "^b[a-z2-7]{20,120}$")


func _content_commitment(value) -> String:
	return "sha256:" + hash_value(value)


func _matches(value: String, pattern: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	return regex.search(value) != null


func _sorted_dictionary_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	return keys


func _offline_receipt(status: String) -> Dictionary:
	return {
		"arbitrary_code_executed": false,
		"blockchain_write_performed": false,
		"interface_mode": INTERFACE_MODE,
		"ipfs_add_performed": false,
		"model_executed": false,
		"network_io_performed": false,
		"private_material_requested": false,
		"status": status,
	}


func _failure(reason: String) -> Dictionary:
	return {
		"interface_mode": INTERFACE_MODE,
		"ok": false,
		"reason": reason,
	}


static func _cid_v1_dag_json(digest_hex: String) -> String:
	# CIDv1 + dag-json multicodec (0x0129) + sha2-256 multihash.
	var bytes := PackedByteArray([0x01, 0xa9, 0x02, 0x12, 0x20])
	for index in range(0, digest_hex.length(), 2):
		bytes.append(int(digest_hex.substr(index, 2).hex_to_int()))
	return "b" + _base32_lower(bytes)


static func _base32_lower(bytes: PackedByteArray) -> String:
	const ALPHABET := "abcdefghijklmnopqrstuvwxyz234567"
	var output := ""
	var buffer := 0
	var bit_count := 0
	for byte in bytes:
		buffer = (buffer << 8) | int(byte)
		bit_count += 8
		while bit_count >= 5:
			bit_count -= 5
			output += ALPHABET[(buffer >> bit_count) & 31]
			buffer &= (1 << bit_count) - 1 if bit_count > 0 else 0
	if bit_count > 0:
		output += ALPHABET[(buffer << (5 - bit_count)) & 31]
	return output
