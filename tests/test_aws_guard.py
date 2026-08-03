import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "guards"))
import aws


def test_allows_sts_get_caller_identity():
    assert aws.decide(["sts", "get-caller-identity"]) is True


def test_allows_sts_get_caller_identity_with_flags():
    assert aws.decide(["sts", "get-caller-identity", "--output", "json"]) is True


def test_denies_s3_ls():
    assert aws.decide(["s3", "ls"]) is False


def test_denies_ec2_describe_instances():
    assert aws.decide(["ec2", "describe-instances"]) is False


def test_denies_ec2_terminate_instances():
    assert aws.decide(["ec2", "terminate-instances", "--instance-ids", "i-123"]) is False


def test_denies_iam_create_user():
    assert aws.decide(["iam", "create-user", "--user-name", "evil"]) is False


def test_denies_sts_assume_role():
    assert aws.decide(["sts", "assume-role"]) is False


def test_denies_empty_argv():
    assert aws.decide([]) is False
