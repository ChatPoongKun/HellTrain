python -m pip install -r requirements.txt
python ../.agents/Tests/CardTaxonomy/validate_card_taxonomy.py
if errorlevel 1 exit /b %errorlevel%
python risucard.py
