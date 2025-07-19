resource "aws_secretsmanager_secret" "db_password01" {
  name = "devops-interview-db-password01"
}

resource "aws_secretsmanager_secret_version" "db_password_value01" {
  secret_id     = aws_secretsmanager_secret.db_password01.id
  secret_string = "changeMe123!" # Use a secure value in production
}


# DB Subnet Group
resource "aws_db_subnet_group" "interview_db_subnet_group" {
  name       = "devops-interview-db-subnet-group"
  subnet_ids = [module.vpc.private_subnets[0], module.vpc.private_subnets[1]]


  tags = {
    Name = "devops-interview-db-subnet-group"
  }
}

resource "aws_db_instance" "devops_interview_db" {
  identifier           = "devops-interview-db"
  engine               = "postgres"
  engine_version       = "11.22-rds.20240418"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  storage_type         = "gp2"
  db_name              = "interviewdb"
  username             = "appuser"
  password             = aws_secretsmanager_secret_version.db_password_value01.secret_string
  # Networking
  db_subnet_group_name   = aws_db_subnet_group.interview_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot = true

  tags = {
    Environment = "interview"
  }
}
