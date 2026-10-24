# Phoenix — freelance operations assistant

Stage 1: requirement intake with Gemini + deterministic template matching.

## What this stage does
1. Reads a requirement from `--text` or a UTF-8 text file.
2. Uses Gemini to produce the structured spec.
3. Matches the spec against `templates.json` using exact normalized labels and explicit rules.
4. Records the lead in `leads.json`, an event in `history.json`, and review files in `builds/<lead-id>/`.

## Safety boundary
Phoenix does **not** clone repositories, build a client deliverable, submit to Upwork/Fiverr,
contact clients, or deliver anything. Human review and all client-platform actions remain
manual and under Teja's control. `submission_status` is always `manual_only` in this stage.

## Repository layout
```text
phoenix/
├── .github/workflows/phoenix.yml
├── builds/
├── phoenix.py
├── templates.json
├── leads.json
├── history.json
└── README.md
```

## Run locally (Termux)
```bash
export GEMINI_API_KEY="your-key"
python phoenix.py --text "Build a web FAQ chatbot with text chat and conversation history"
# or
python phoenix.py --file requirement.txt --client-name "Example Client"
```

No third-party Python packages are required. The script uses Python's standard library.

## GitHub Actions
Add repository secret `GEMINI_API_KEY`. The workflow can be manually triggered.
The scheduled trigger is enabled in the workflow; GitHub may restrict scheduled runs
for inactive repositories and private-repository free-minute usage depends on plan.
