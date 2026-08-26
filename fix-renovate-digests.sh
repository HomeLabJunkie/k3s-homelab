#!/bin/bash

# Script to remove digest pins from GitHub Actions in workflow files
# This fixes Renovate's "Could not determine new digest" errors after git history changes

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Fixing GitHub Actions digest pins in workflow files...${NC}\n"

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo -e "${RED}Error: Not in a git repository root directory${NC}"
    echo "Please run this script from your repository root (~/k3s)"
    exit 1
fi

# Check if .github/workflows exists
if [ ! -d ".github/workflows" ]; then
    echo -e "${RED}Error: .github/workflows directory not found${NC}"
    exit 1
fi

# Find all workflow YAML files
workflow_files=$(find .github/workflows -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null)

if [ -z "$workflow_files" ]; then
    echo -e "${RED}No workflow files found in .github/workflows/${NC}"
    exit 1
fi

echo -e "${YELLOW}Found workflow files:${NC}"
echo "$workflow_files"
echo ""

# Create backups and process files
for file in $workflow_files; do
    echo -e "${YELLOW}Processing: $file${NC}"

    # Create backup
    cp "$file" "${file}.bak"

    # Remove digest pins - pattern matches:
    # uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # 5.0.1
    # and replaces with:
    # uses: actions/checkout@v5.0.1

    sed -i -E 's|uses: ([^@]+)@[a-f0-9]{40,64} # ([0-9]+\.[0-9]+\.[0-9]+)|uses: \1@v\2|g' "$file"

    echo -e "  ${GREEN}✓${NC} Updated $file"
done

# Show what changed
echo -e "\n${GREEN}=== Changes Made ===${NC}\n"
for file in $workflow_files; do
    if [ -f "${file}.bak" ]; then
        echo -e "${YELLOW}=== $file ===${NC}"
        diff -u "${file}.bak" "$file" || true
        echo ""
    fi
done

echo -e "${GREEN}✓ All workflow files processed!${NC}\n"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Review the changes above"
echo "2. If everything looks good:"
echo "   git add .github/workflows/"
echo "   git commit -m 'fix: remove invalid digest pins from GitHub Actions'"
echo "   git push"
echo ""
echo "3. Wait for Renovate to run and recreate the digest pins"
echo ""
echo -e "${YELLOW}To restore original files if needed:${NC}"
echo "   for f in .github/workflows/*.bak; do mv \$f \${f%.bak}; done"
echo ""
echo -e "${YELLOW}To remove backup files after committing:${NC}"
echo "   rm .github/workflows/*.bak"
