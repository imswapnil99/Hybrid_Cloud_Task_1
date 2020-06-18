//========================================================================================================
//                          For this setup First Mention providers : AWS  
//========================================================================================================

provider "aws" {
 region = "ap-south-1"
 profile = "Sunny"
}

//========================================================================================================
//                                   Creating the key
//========================================================================================================


resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key_task_1" {
  key_name   = "key12321"
  public_key = tls_private_key.example.public_key_openssh
}

//========================================================================================================
//                           Creating the security group allow port number 80 and 22. 
//========================================================================================================


resource "aws_security_group" "sec_grp" {
  name = "t1sg"
  description = "Allow SSH and HTTP inbound traffic"
  

  ingress {
    description = "For SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "For HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sec_grp_1"
  }
}

//========================================================================================================
//                    Now launch an instance by setting up ssh connection to ec2-user 
//========================================================================================================

resource "aws_instance" "my_instance"  {
  ami = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.key_task_1.key_name
  security_groups = [aws_security_group.sec_grp.name]

   connection {
  type = "ssh"
  user = "ec2-user"
  private_key = tls_private_key.example.private_key_pem
  host = aws_instance.my_instance.public_ip
 }

//========================================================================================================
//           Using remote-exec install git , httpd and php and Start httpd service  
//========================================================================================================

 provisioner "remote-exec" {
  inline = [
   "sudo yum install httpd git -y",
   "sudo systemctl start httpd",
   "sudo systemctl enable httpd",
  ]
 }

  tags = {
    Name = "terros1"
  }
  
  
	 provisioner "local-exec" {
		  when = destroy
		  command = "rmdir /s /q images"
		       }
  
}


//========================================================================================================
//                            Downloading images from git to local host
//========================================================================================================

resource "null_resource" "image_local"{
  provisioner "local-exec" {
    command = "git clone https://github.com/imswapnil99/website.git images"
	
	
  }
}

//========================================================================================================
//                Creating an EBS volume in the same availability zone of ec2 instance. 
//========================================================================================================

resource "aws_ebs_volume" "ebsvol" {
  availability_zone = aws_instance.my_instance.availability_zone
  size = 2

  tags = {
    Name = "os_vol_1"
  }
}

//========================================================================================================
//                                   Attach it to ec2 instance
//========================================================================================================

resource "aws_volume_attachment" "ebsvol_attach" {
  depends_on = [
		aws_ebs_volume.ebsvol,
		aws_instance.my_instance ]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ebsvol.id
  instance_id = aws_instance.my_instance.id
  force_detach = true

}


output "myos_ip" {
  value = aws_instance.my_instance.public_ip
}


//========================================================================================================
//                                          Storing ip locally    
//========================================================================================================

resource "null_resource" "null_local1"  {
	provisioner "local-exec" {
	    command = "echo  ${aws_instance.my_instance.public_ip} > publicip.txt"
  	}
}

//========================================================================================================
//                               Attaching Volume ,formating and Mounting   
//========================================================================================================


resource "null_resource" "null_remote_2"  {
  depends_on = [
    aws_volume_attachment.ebsvol_attach,
  ]

 
  connection {
  type = "ssh"
  user = "ec2-user"
  private_key = tls_private_key.example.private_key_pem
  host = aws_instance.my_instance.public_ip
 }
 
  
 provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdh",
      "sudo mount  /dev/xvdh  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/imswapnil99/website.git /var/www/html/"
    ]
  }
}



//========================================================================================================
//                            Create a S3 bucket to store our files permanently.   
//========================================================================================================

 
resource "aws_s3_bucket" "my_bucket" {
      depends_on = [
          aws_volume_attachment.ebsvol_attach,
       ]

  bucket = "myuniqueshkbucket"
  acl    = "public-read"
  force_destroy = true
  
  tags = {
    Name = "myuniqueshkbucket"
	Environment = "Dev"
  }
  versioning {
   enabled = true
  }
  
}
//========================================================================================================
//                                Adding Object on S3 bucket  
//========================================================================================================

resource "aws_s3_bucket_object" "terraobject" {
        depends_on = [
              aws_s3_bucket.my_bucket ,
			  null_resource.image_local
         ]
		
		
		bucket = aws_s3_bucket.my_bucket.bucket
        key = "image.jpg"
        source = "images/image.jpg"
        content_type = "image/jpg"
        acl = "public-read"
        
}

locals {
   s3_origin_id = "S3-${aws_s3_bucket.my_bucket.bucket}"
   }


//========================================================================================================
//                                Creating Origin Access Identity  
//========================================================================================================


resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "Some comment OAI"
}



//========================================================================================================
//                                Creating AWS Cloud Front Distribution  
//========================================================================================================


resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.my_bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
  origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
}
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "My cloudfront"
  default_root_object = "image.jpg"


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }


  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
  depends_on = [
    aws_s3_bucket.my_bucket
   ]

connection {
  type = "ssh"
  user = "ec2-user"
  private_key = tls_private_key.example.private_key_pem
  host = aws_instance.my_instance.public_ip
 }


//========================================================================================================
//                                      Tweaking webpage 
//========================================================================================================


provisioner "remote-exec" {
     
      inline = [
          "sudo su << EOF",
           "echo \"<img src=\"https://\"${aws_cloudfront_distribution.s3_distribution.domain_name}\"/image.jpg\">\" >> /var/www/html/index.html",

            "EOF"
      ]
  }
}




resource "null_resource" "nulllocal1"  {
  depends_on = [
    aws_cloudfront_distribution.s3_distribution,
  ]

  provisioner "local-exec" {
    command = "start chrome  ${aws_instance.my_instance.public_ip}"
  }
}

//========================================================================================================
//                                     Creating EBS snapshot volume
//========================================================================================================


resource "aws_ebs_snapshot" "my_snapshot" {
depends_on = [
    null_resource.nulllocal1,
  ]
  volume_id = aws_ebs_volume.ebsvol.id

  tags = {
    Name = "My_snapshot_tf"
  }
}


//========================================================================================================
//                               This will be Final Output
//========================================================================================================

output "my_cloudfront_domain_name" {
   value = aws_cloudfront_distribution.s3_distribution.domain_name
 }

