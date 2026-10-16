/*
 * GIT - The information manager from hell
 *
 * Copyright (C) Linus Torvalds, 2005
 */
#define USE_THE_REPOSITORY_VARIABLE
#include "builtin.h"
#include "config.h"
#include "environment.h"
#include "gettext.h"
#include "hex.h"
#include "object-name.h"
#include "odb.h"

#include "commit.h"
#include "parse-options.h"

static const char * const commit_tree_usage[] = {
	N_("git commit-tree <tree> [(-p <parent>)...]"),
	N_("git commit-tree [(-p <parent>)...] [-S[<keyid>]] [(-m <message>)...]\n"
	   "                [(-F <file>)...] [--context <commit>] <tree>"),
	NULL
};

static const char *sign_commit;

static void new_parent(struct commit *parent, struct commit_list **parents_p)
{
	struct object_id *oid = &parent->object.oid;
	struct commit_list *parents;
	for (parents = *parents_p; parents; parents = parents->next) {
		if (parents->item == parent) {
			error(_("duplicate parent %s ignored"), oid_to_hex(oid));
			return;
		}
		parents_p = &parents->next;
	}
	commit_list_insert(parent, parents_p);
}

static int parse_parent_arg_callback(const struct option *opt,
		const char *arg, int unset)
{
	struct object_id oid;
	struct commit_list **parents = opt->value;

	BUG_ON_OPT_NEG_NOARG(unset, arg);

	if (repo_get_oid_commit(the_repository, arg, &oid))
		die(_("not a valid object name %s"), arg);

	odb_assert_oid_type(the_repository->objects, &oid, OBJ_COMMIT);
	new_parent(lookup_commit(the_repository, &oid), parents);
	return 0;
}

static int parse_message_arg_callback(const struct option *opt,
		const char *arg, int unset)
{
	struct strbuf *buf = opt->value;

	BUG_ON_OPT_NEG_NOARG(unset, arg);

	if (buf->len)
		strbuf_addch(buf, '\n');
	strbuf_addstr(buf, arg);
	strbuf_complete_line(buf);

	return 0;
}

static int parse_file_arg_callback(const struct option *opt,
		const char *arg, int unset)
{
	int fd;
	struct strbuf *buf = opt->value;

	BUG_ON_OPT_NEG_NOARG(unset, arg);

	if (buf->len)
		strbuf_addch(buf, '\n');
	if (!strcmp(arg, "-"))
		fd = 0;
	else {
		fd = xopen(arg, O_RDONLY);
	}
	if (strbuf_read(buf, fd, 0) < 0)
		die_errno(_("git commit-tree: failed to read '%s'"), arg);
	if (fd && close(fd))
		die_errno(_("git commit-tree: failed to close '%s'"), arg);

	return 0;
}

int cmd_commit_tree(int argc,
		    const char **argv,
		    const char *prefix,
		    struct repository *repo UNUSED)
{
	static struct strbuf buffer = STRBUF_INIT;
	struct commit_list *parents = NULL;
	struct object_id tree_oid;
	struct object_id commit_oid;
	struct object_id context_oid;
	const char *context = NULL;
	struct commit_extra_header *extra = NULL, **tail = &extra;

	struct option options[] = {
		OPT_CALLBACK_F('p', NULL, &parents, N_("parent"),
			N_("id of a parent commit object"), PARSE_OPT_NONEG,
			parse_parent_arg_callback),
		OPT_CALLBACK_F('m', NULL, &buffer, N_("message"),
			N_("commit message"), PARSE_OPT_NONEG,
			parse_message_arg_callback),
		OPT_CALLBACK_F('F', NULL, &buffer, N_("file"),
			N_("read commit log message from file"), PARSE_OPT_NONEG,
			parse_file_arg_callback),
		{
			.type = OPTION_STRING,
			.short_name = 'S',
			.long_name = "gpg-sign",
			.value = &sign_commit,
			.argh = N_("key-id"),
			.help = N_("GPG sign commit"),
			.flags = PARSE_OPT_OPTARG,
			.defval = (intptr_t) "",
		},
		OPT_STRING(0, "context", &context, N_("commit"),
			   N_("context checkpoint the commit was made from")),
		OPT_END()
	};
	int ret;

	repo_config(the_repository, git_default_config, NULL);

	show_usage_with_options_if_asked(argc, argv,
					 commit_tree_usage, options);

	argc = parse_options(argc, argv, prefix, options, commit_tree_usage, 0);

	if (argc != 1)
		die(_("must give exactly one tree"));

	if (repo_get_oid_tree(the_repository, argv[0], &tree_oid))
		die(_("not a valid object name %s"), argv[0]);

	if (!buffer.len) {
		if (strbuf_read(&buffer, 0, 0) < 0)
			die_errno(_("git commit-tree: failed to read"));
	}

	if (context) {
		struct commit *c;

		if (repo_get_oid_commit(the_repository, context, &context_oid) ||
		    !(c = lookup_commit_reference(the_repository, &context_oid)))
			die(_("not a valid commit name %s"), context);
		oidcpy(&context_oid, &c->object.oid);
	}

	append_merge_tag_headers(parents, &tail);
	if (context)
		append_context_header(&context_oid, &tail);
	if (commit_tree_extended(buffer.buf, buffer.len, &tree_oid, parents,
				 &commit_oid, NULL, NULL, sign_commit, extra)) {
		ret = 1;
		goto out;
	}

	printf("%s\n", oid_to_hex(&commit_oid));
	ret = 0;

out:
	free_commit_extra_headers(extra);
	commit_list_free(parents);
	strbuf_release(&buffer);
	return ret;
}
