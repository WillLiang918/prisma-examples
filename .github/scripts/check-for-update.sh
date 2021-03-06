#!/bin/sh

set -eu

channel="$1"
branch="$2"

no_negatives () {
	echo "$(( $1 < 0 ? 0 : $1 ))"
}

echo "setting up ssh repo"

mkdir -p ~/.ssh
echo "$SSH_KEY" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
ssh-keyscan github.com >> ~/.ssh/known_hosts

git config --global user.email "prismabots@gmail.com"
git config --global user.name "Prismo"

# prepare script: read package.json but ignore workspace package.json files
pkg="var pkg=require('./package.json'); if (pkg.workspaces) { process.exit(0); }"

# since GH actions are limited to 5 minute cron jobs, just run this continuously for 5 minutes
minutes=5 # cron job runs each x minutes
interval=10 # run each x seconds
i=0
count=$(((minutes * 60) / interval))
echo "running loop $count times"
while [ $i -le $count ]; do
	# increment to prevent forgetting incrementing, and also prevent overlapping with the next 5-minute job
	i=$(( i + 1 ))
	echo "run $i"

	start=$(date "+%s")

	dir=$(pwd)

	git pull origin $branch --ff-only
	packages=$(find . -not -path "*/node_modules/*" -type f -name "package.json")

	echo "checking info..."

	v=$(yarn info prisma2@$channel --json | jq '.data["dist-tags"].alpha' | tr -d '"')

	echo "$packages" | tr ' ' '\n' | while read -r item; do
		echo "checking $item"
		cd "$(dirname "$item")/"

		vPrisma2="$(node -e "$pkg;console.log(pkg.devDependencies['prisma2'])")"

		if [ "$vPrisma2" != "" ]; then
			if [ "$v" != "$vPrisma2" ]; then
				echo "$item: prisma2 expected $v, actual $vPrisma2"
				yarn add "prisma2@$v" --dev
			fi

			vPrismaClient="$(node -e "$pkg;console.log(pkg.dependencies['@prisma/client'])")"

			if [ "$v" != "$vPrismaClient" ]; then
				echo "$item: @prisma/client expected $v, actual $vPrismaClient"
				yarn add "@prisma/client@$v"
			fi
		fi

		cd "$dir"
	done

	if [ -z "$(git status -s)" ]; then
		echo "no changes"
		end=$(date "+%s")
		diff=$(echo "$end - $start" | bc)
		remaining=$((interval - 1 - diff))
		echo "took $diff seconds, sleeping for $remaining seconds"
		sleep "$(no_negatives $remaining)"

		continue
	fi

	echo "changes, upgrading..."

	git commit -am "chore(packages): bump prisma2 to $v"

	# fail silently if the unlikely event happens that this change already has been pushed either manually
	# or by an overlapping upgrade action
	git pull origin "$branch" --rebase || true
	git push origin HEAD:$branch || true

	echo "pushed commit"

	end=$(date "+%s")
	diff=$(echo "$end - $start" | bc)
	remaining=$((interval - 1 - diff))
	# upgrading usually takes longer than a few individual loop runs, so skip test runs which would have passed by now
	skip=$((remaining / interval))
	i=$((i - skip))
	echo "took $diff seconds, skipping $skip x $interval second runs"
done

echo "done"
